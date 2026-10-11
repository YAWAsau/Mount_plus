/* Shared native query engine. Included by mounttx.c; never executes shell text. */
#include <ctype.h>

static bool proc_uid(pid_t pid, unsigned long *uid) {
    char path[64], line[512]; snprintf(path,sizeof(path),"/proc/%d/status",pid);
    FILE *f=fopen(path,"r"); if(!f) return false;
    bool ok=false;
    while(fgets(line,sizeof(line),f)) if(sscanf(line,"Uid: %lu",uid)==1) {ok=true;break;}
    fclose(f); return ok;
}
static int runtime_pids(int user, const char *mode) {
    pid_t base[MAX_PIDS]; int n=core_pids_base(user,base,MAX_PIDS);
    char (*seen)[128]=NULL; size_t used=0,cap=0;
    if(strcmp(mode,"user")) for(int i=0;i<n;i++) {
        char ns[128]; if(!get_ns_link(base[i],ns,sizeof(ns))) continue;
        void *p=realloc(seen,(used+1)*sizeof(*seen)); if(!p){free(seen);return 1;} seen=p;
        strcpy(seen[used++],ns); cap=used;
        if(strcmp(mode,"apps")) printf("%d\n",base[i]);
    }
    if(!strcmp(mode,"core")){free(seen);return 0;}
    DIR *d=opendir("/proc"); if(!d){free(seen);return 1;}
    struct dirent *de; int rc=0;
    while((de=readdir(d))) {
        int pid; unsigned long uid; char ns[128];
        if(!parse_int_field(de->d_name,&pid)||!pid||!proc_uid(pid,&uid)) continue;
        unsigned long long lo=(unsigned long long)user*100000, hi=lo+99999;
        if(uid<lo||uid>hi||(!strcmp(mode,"apps")&&uid<lo+10000))continue;
        if(!get_ns_link(pid,ns,sizeof(ns)))continue;
        bool duplicate=false;
        if(strcmp(mode,"user"))for(size_t i=0;i<used;i++)if(!strcmp(seen[i],ns)){duplicate=true;break;}
        if(duplicate)continue;
        if(used==cap){size_t nc=cap?cap*2:32;void *p=realloc(seen,nc*sizeof(*seen));if(!p){rc=1;break;}seen=p;cap=nc;}
        strcpy(seen[used++],ns);printf("%d\n",pid);
    }
    closedir(d);free(seen);return rc;
}
static bool source_identity(const char *path,char *out,size_t len) {
    struct stat st;if(stat(path,&st))return false;
    snprintf(out,len,"%llu:%llu",(unsigned long long)st.st_dev,(unsigned long long)st.st_ino);return true;
}
static bool source_stale(const Row *r) {
    char now[128],path[PATH_MAX];
    if(!source_identity(r->src,now,sizeof(now)))return true;
    snprintf(path,sizeof(path),"%s/active_source_state.tsv",g_opt.runtime);
    FILE *f=fopen(path,"r");bool found=false,stale=false;
    if(f){char *line=NULL;size_t cap=0;
        while(getline(&line,&cap,f)>=0){trim_crlf(line);char *rest=line,*v[5];
            for(int i=0;i<5;i++)v[i]=strsep(&rest,"|");int u;
            if(!v[4]||rest||!parse_int_field(v[0],&u))continue;
            if(u==r->user&&!strcmp(v[1],r->lower)&&!strcmp(v[2],r->src)&&!strcmp(v[3],r->policy)){
                found=true;stale=strcmp(v[4],now)!=0;break;
            }
        }free(line);fclose(f);
    }
    return found?stale:!strcmp(r->policy,"bindfs_shared");
}
static bool row_is_mounted(const Row *r) {
    bool fuse=!strcmp(r->policy,"bindfs_shared");
    pid_t pid=fuse?media_pid_for_user(r->user):1;
    int orig=-1;if(pid<=0||setns_pid_restore(pid,&orig))return false;
    bool ok=fuse?is_bindfs_mounted_here(r->lower):(is_any_mount_here(r->lower)&&stat_same(r->src,r->lower));
    restore_ns(orig);return ok;
}
/* A replaced source can still own its old kernel bind. Prove ownership with
 * the committed source identity before allowing preflight to replace it. */
static bool target_unknown(const char *src,const char *lower,const char *policy) {
    int orig=-1;if(setns_pid_restore(1,&orig))return true;
    bool unknown=is_any_mount_here(lower);
    if(unknown&&(!strcmp(policy,"bindfs_shared")?is_bindfs_mounted_here(lower):stat_same(src,lower)))unknown=false;
    if(unknown&&strcmp(policy,"bindfs_shared")){
        char path[PATH_MAX];snprintf(path,sizeof(path),"%s/active_source_state.tsv",g_opt.runtime);
        FILE *f=fopen(path,"r");if(f){char *line=NULL;size_t cap=0;
            while(getline(&line,&cap,f)>=0){char *p=line,*v[5];for(int i=0;i<5;i++)v[i]=strsep(&p,"|");
                Row r={0};if(!v[4]||!parse_int_field(v[0],&r.user)||strcmp(v[1],lower)||strcmp(v[2],src)||strcmp(v[3],policy))continue;
                if(strlen(src)>=sizeof(r.src)||strlen(lower)>=sizeof(r.lower)||strlen(policy)>=sizeof(r.policy))break;
                strcpy(r.src,src);strcpy(r.lower,lower);strcpy(r.policy,policy);
                if(saved_source_matches_lower(&r))unknown=false;break;
            }free(line);fclose(f);
        }
    }
    restore_ns(orig);return unknown;
}
/* Strict scan mode observes only the actual scanner namespace. */
static bool row_visible(const Row *r,bool strict) {
    char before[128],after[128];
    if(!source_identity(r->src,before,sizeof(before)))return false;
    int orig=-1;
    if(strict){pid_t pid=media_pid_for_user(r->user);if(pid<=0||setns_pid_restore(pid,&orig))return false;}
    bool ok=test_visible_once(r);
    if(!ok){msleep_int(120);ok=test_visible_once(r);}
    restore_ns(orig);
    return ok&&source_identity(r->src,after,sizeof(after))&&!strcmp(before,after);
}
static void json_string(const char *s) {
    putchar('"');for(const unsigned char *p=(const unsigned char *)s;*p;p++){
        switch(*p){case '"':fputs("\\\"",stdout);break;case '\\':fputs("\\\\",stdout);break;
        default:if(*p<32)printf("\\u%04x",*p);else putchar(*p);}
    }putchar('"');
}
static void json_key(const char *key,const char *value){json_string(key);putchar(':');json_string(value);}
static void read_key(const char *path,const char *key,char *out,size_t size) {
    *out=0;FILE *f=fopen(path,"r");if(!f)return;
    char *line=NULL;size_t cap=0,n=strlen(key);
    while(getline(&line,&cap,f)>=0)if(!strncmp(line,key,n)&&line[n]=='='){trim_crlf(line);snprintf(out,size,"%s",line+n+1);break;}
    free(line);fclose(f);
}
static bool profile_value(const char *parsed,const char *group,char *out,size_t len) {
    char p[PATH_MAX];snprintf(p,sizeof(p),"%s/profiles",parsed);
    FILE *f=fopen(p,"r");if(!f)return false;
    char line[512];bool ok=false;
    while(fgets(line,sizeof(line),f)){trim_crlf(line);char *bar=strchr(line,'|');if(!bar)continue;*bar++=0;
        if(!strcmp(line,group)){snprintf(out,len,"%s",bar);ok=true;break;}}
    fclose(f);return ok;
}
static int status_native(const char *version,const char *conf,const char *parsed,const char *device) {
    RowSet *rs=calloc(1,sizeof(*rs));if(!rs)return 1;
    char p[PATH_MAX],partition[128],mp[PATH_MAX],fs[128]="-",state[64];
    snprintf(p,sizeof(p),"%s/mounts.all",parsed);
    if(read_rows(p,rs)){free(rs);return 1;}
    snprintf(p,sizeof(p),"%s/global",parsed);read_key(p,"partition",partition,sizeof(partition));read_key(p,"mount_point",mp,sizeof(mp));
    snprintf(p,sizeof(p),"%s/config.state",g_opt.runtime);read_key(p,"STATE",state,sizeof(state));
    int orig=-1;bool mounted=false;
    if(!setns_pid_restore(1,&orig)){mounted=mount_entry_at(mp,NULL,0,fs,sizeof(fs));restore_ns(orig);}
    putchar('{');json_key("version",version);putchar(',');json_key("config",conf);
    printf(",\"configValid\":%s,",!strcmp(state,"valid")?"true":"false");json_key("partition",partition);putchar(',');json_key("device",device);putchar(',');json_key("mountPoint",mp);putchar(',');json_key("fsType",fs);
    printf(",\"partitionMounted\":%s,\"profiles\":[",mounted?"true":"false");
    snprintf(p,sizeof(p),"%s/profiles",parsed);FILE *f=fopen(p,"r");bool first=true;
    if(f){char line[512];while(fgets(line,sizeof(line),f)){
        trim_crlf(line);char *bar=strchr(line,'|');if(!bar)continue;*bar++=0;
        if(!first)putchar(',');first=false;putchar('{');json_key("group",line);putchar(',');json_key("selected",bar);fputs(",\"options\":[",stdout);
        bool of=true;for(int i=0;i<rs->count;i++){Row *r=&rs->rows[i];if(strcmp(r->group,line))continue;
            bool dup=false;for(int j=0;j<i;j++)if(!strcmp(rs->rows[j].group,line)&&!strcmp(rs->rows[j].profile,r->profile)){dup=true;break;}if(dup)continue;
            if(!of)putchar(',');of=false;putchar('{');json_key("value",r->profile);putchar(',');json_key("name",r->name);putchar(',');json_key("source",r->src);putchar(',');json_key("target",r->target);putchar('}');
        }fputs("]}",stdout);
    }fclose(f);}
    fputs("],\"mounts\":[",stdout);
    for(int i=0;i<rs->count;i++){
        Row *r=&rs->rows[i];char selected[128]="";bool active=r->enabled;
        if(*r->group)active=active&&profile_value(parsed,r->group,selected,sizeof(selected))&&!strcmp(selected,r->profile);
        bool m=path_is_dir(r->src)&&!source_stale(r)&&row_is_mounted(r);
        bool v=m&&row_visible(r,false);
        if(i)putchar(',');putchar('{');json_key("name",r->name);printf(",\"user\":%d,",r->user);json_key("source",r->src);putchar(',');json_key("target",r->target);
        printf(",\"enabled\":%s,\"active\":%s,\"mounted\":%s,\"visible\":%s,",r->enabled?"true":"false",active?"true":"false",m?"true":"false",v?"true":"false");
        json_key("group",r->group);putchar(',');json_key("profile",r->profile);putchar(',');json_key("policy",r->policy);printf(",\"create\":%s,",r->create?"true":"false");json_key("migrate",r->migrate);putchar('}');
    }fputs("]}\n",stdout);free(rs);return ferror(stdout)?1:0;
}
static int runtime_main(int argc,char **argv) {
    if(argc<2)return -1;const char *cmd=argv[1];
    if(!strcmp(cmd,"pids")){int user;if(argc!=4||!parse_int_field(argv[2],&user))return 2;
        if(strcmp(argv[3],"core")&&strcmp(argv[3],"all")&&strcmp(argv[3],"apps")&&strcmp(argv[3],"user"))return 2;
        return runtime_pids(user,argv[3]);}
    if(!strcmp(cmd,"source-sig")){char sig[128];if(argc!=3)return 2;if(!source_identity(argv[2],sig,sizeof(sig)))return 1;puts(sig);return 0;}
    if(!strcmp(cmd,"mount-query")){
        int pid,orig=-1;if((argc!=5&&argc!=6)||!parse_int_field(argv[3],&pid)||pid<=0)return 2;
        if(setns_pid_restore(pid,&orig))return 1;
        char src[PATH_MAX],fs[128];bool ok=false;
        if(!strcmp(argv[2],"same")&&argc==6)ok=stat_same(argv[4],argv[5]);
        else if(!strcmp(argv[2],"fuse"))ok=is_bindfs_mounted_here(argv[4]);
        else {ok=mount_entry_at(argv[4],src,sizeof(src),fs,sizeof(fs));
            if(ok&&!strcmp(argv[2],"source"))puts(src);
            else if(ok&&!strcmp(argv[2],"type"))puts(fs);
            else if(strcmp(argv[2],"present"))ok=false;
        }
        restore_ns(orig);return ok?0:1;
    }
    if(!strcmp(cmd,"occupied")){if(argc!=6)return 2;g_opt.runtime=argv[5];return target_unknown(argv[2],argv[3],argv[4])?0:1;}
    if(!strcmp(cmd,"unmount-owned")){
        Row r={0};int pid;if(argc!=7||!parse_int_field(argv[2],&pid)||pid<=0)return 2;
        if(sscanf(argv[4],"/data/media/%d/",&r.user)!=1||r.user<0)return 2;
        if(strlen(argv[3])>=sizeof(r.src)||strlen(argv[4])>=sizeof(r.lower)||strlen(argv[5])>=sizeof(r.policy))return 2;
        strcpy(r.src,argv[3]);strcpy(r.lower,argv[4]);strcpy(r.policy,argv[5]);g_opt.runtime=argv[6];
        return unmount_pid_if_ours(pid,&r)?1:0;
    }
    if(!strcmp(cmd,"status")){if(argc!=7)return 2;g_opt.runtime=argv[5];return status_native(argv[2],argv[3],argv[4],argv[6]);}
    if(!strcmp(cmd,"health")){
        if(argc!=9)return 2;Row r={0};if(!parse_int_field(argv[3],&r.user))return 2;
        if(strlen(argv[4])>=sizeof(r.src)||strlen(argv[5])>=sizeof(r.lower)||strlen(argv[6])>=sizeof(r.policy)||strlen(argv[7])>=sizeof(r.visible))return 2;
        strcpy(r.src,argv[4]);strcpy(r.lower,argv[5]);strcpy(r.policy,argv[6]);strcpy(r.visible,argv[7]);g_opt.runtime=argv[8];
        if(!strcmp(argv[2],"stale"))return source_stale(&r)?0:1;
        if(!strcmp(argv[2],"mounted"))return row_is_mounted(&r)?0:1;
        if(!strcmp(argv[2],"visible"))return row_visible(&r,false)?0:1;
        if(!strcmp(argv[2],"scan"))return !source_stale(&r)&&row_is_mounted(&r)&&row_visible(&r,true)?0:1;
        return 2;
    }return -1;
}
