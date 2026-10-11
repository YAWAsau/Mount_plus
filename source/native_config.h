/* mount.conf is data. Bounds/validation precede publication; no eval/system(). */
typedef struct {char group[128],value[128];} CfgProfile;
typedef struct {char path[PATH_MAX],policy[32];} CfgDir;
typedef struct {
    char partition[128],mp[PATH_MAX],fs[16],quiesce[16];
    CfgProfile profiles[MAX_ROWS];int np;
    CfgDir dirs[MAX_ROWS];int nd;
    RowSet mounts;
} NativeConfig;
static bool cfg_copy(char *dst,size_t size,const char *src){if(strlen(src)>=size)return false;strcpy(dst,src);return true;}
static char *cfg_trim(char *s){while(isspace((unsigned char)*s))s++;char *e=s+strlen(s);while(e>s&&isspace((unsigned char)e[-1]))*--e=0;return s;}
static bool cfg_id(const char *s){if(!*s)return false;for(;*s;s++)if(!((*s>='a'&&*s<='z')||(*s>='A'&&*s<='Z')||isdigit((unsigned char)*s)||strchr("._-",*s)))return false;return true;}
static bool cfg_path(const char *s,bool absolute){
    if(!*s||(absolute?*s!='/':*s=='/'))return false;
    for(const unsigned char *p=(const unsigned char *)s;*p;p++)if(*p<32||*p==127||*p=='|')return false;
    const char *p=s;while(*p){while(*p=='/')p++;const char *e=strchr(p,'/');size_t n=e?(size_t)(e-p):strlen(p);if(n==2&&!strncmp(p,"..",2))return false;if(!e)break;p=e+1;}
    if(!absolute&&(!strcmp(s,".")||!strncmp(s,"./",2)||(strlen(s)>=2&&!strcmp(s+strlen(s)-2,"/."))))return false;
    return true;
}
static bool cfg_join(char *out,size_t n,const char *a,const char *b){size_t z=strlen(a);if(z&&a[z-1]=='/')z--;return snprintf(out,n,"%.*s/%s",(int)z,a,b)<(int)n;}
static bool cfg_source(const char *mp,const char *src,char *out,size_t n){
    if(*src=='/')return cfg_path(src,true)&&cfg_copy(out,n,src);
    return cfg_path(src,false)&&cfg_path(mp,true)&&cfg_join(out,n,mp,src);
}
static bool cfg_target(int user,const char *target,char *lower,char *visible){
    char u[32];snprintf(u,sizeof(u),"%d",user);
    if(*target!='/'){
        if(!cfg_path(target,false))return false;
        return snprintf(lower,PATH_MAX,"/data/media/%d/%s",user,target)<PATH_MAX&&snprintf(visible,PATH_MAX,"/storage/emulated/%d/%s",user,target)<PATH_MAX;
    }
    if(!cfg_path(target,true))return false;
    bool em=!strncmp(target,"/storage/emulated/",18),dm=!strncmp(target,"/data/media/",12);
    if(!em&&!dm)return false;const char *p=target+(em?18:12);size_t len=strcspn(p,"/");
    if(strlen(u)!=len||strncmp(p,u,len))return false;const char *sub=p+len;
    return snprintf(lower,PATH_MAX,"/data/media/%d%s",user,sub)<PATH_MAX&&snprintf(visible,PATH_MAX,"/storage/emulated/%d%s",user,sub)<PATH_MAX;
}
static int cfg_error(int line,const char *message){
    log_msg("錯誤","mount.conf 第 %d 行 %s",line,message);
    fprintf(stderr,"mount.conf 第 %d 行 %s\n",line,message);return 3;
}
static int cfg_fields(char *s,char **v,int limit){int n=0;char *p=s;while(p&&n<limit)v[n++]=strsep(&p,"|");return p?-1:n;}
static const char *cfg_selected(NativeConfig *c,const char *g){for(int i=0;i<c->np;i++)if(!strcmp(c->profiles[i].group,g))return c->profiles[i].value;return NULL;}
static bool cfg_user(int u,const char *users){if(!u||!*users)return true;char match[64];snprintf(match,sizeof(match),"UserInfo{%d:",u);return strstr(users,match)!=NULL;}
static void cfg_row_write(FILE *f,const Row *r){fprintf(f,"%s|%d|%s|%s|%s|%s|%d|%s|%s|%s|%d|%s\n",r->name,r->user,r->src,r->target,r->lower,r->visible,r->enabled,r->group,r->profile,r->policy,r->create,r->migrate);}
static int cfg_publish(NativeConfig *c,const char *out,bool global){
    char tmp[PATH_MAX];if(snprintf(tmp,sizeof(tmp),"%s.tmp.XXXXXX",out)>=(int)sizeof(tmp)||!mkdtemp(tmp))return 2;
    const char *names[]={"global","profiles","dirs","mounts.all","mounts.desired"};int rc=0;
    for(int i=0;i<5&&!rc;i++){
        char path[PATH_MAX];if(snprintf(path,sizeof(path),"%s/%s",tmp,names[i])>=(int)sizeof(path)){rc=2;break;}
        int fd=open(path,O_WRONLY|O_CREAT|O_EXCL|O_CLOEXEC,0600);FILE *f=fd<0?NULL:fdopen(fd,"w");if(!f){if(fd>=0)close(fd);rc=2;break;}
        if(!i)fprintf(f,"partition=%s\nmount_point=%s\nfs=%s\nvendor_gallery_quiesce=%s\n",c->partition,c->mp,c->fs,c->quiesce);
        else if(!global){
            if(i==1)for(int j=0;j<c->np;j++)fprintf(f,"%s|%s\n",c->profiles[j].group,c->profiles[j].value);
            if(i==2)for(int j=0;j<c->nd;j++)fprintf(f,"%s|%s\n",c->dirs[j].path,c->dirs[j].policy);
            if(i>=3)for(int j=0;j<c->mounts.count;j++){
                Row *r=&c->mounts.rows[j];const char *s=*r->group?cfg_selected(c,r->group):NULL;
                if(i==3||(r->enabled&&(!*r->group||(s&&!strcmp(s,r->profile)))))cfg_row_write(f,r);
            }
        }
        if(fflush(f)||fsync(fd))rc=2;if(fclose(f))rc=2;
    }
    if(!rc&&mkdir_p(out,0700))rc=2;
    for(int i=0;i<5&&!rc;i++){char a[PATH_MAX],b[PATH_MAX];if(snprintf(a,sizeof(a),"%s/%s",tmp,names[i])>=(int)sizeof(a)||snprintf(b,sizeof(b),"%s/%s",out,names[i])>=(int)sizeof(b)||rename(a,b))rc=2;}
    for(int i=0;i<5;i++){char p[PATH_MAX];if(snprintf(p,sizeof(p),"%s/%s",tmp,names[i])<(int)sizeof(p))unlink(p);}rmdir(tmp);return rc;
}
static int config_parse(const char *path,const char *out,const char *users,bool global) {
    FILE *f=fopen(path,"r");if(!f){cfg_error(0,"設定檔不存在");return 2;}
    NativeConfig *c=calloc(1,sizeof(*c));if(!c){fclose(f);return 2;}strcpy(c->fs,"auto");strcpy(c->quiesce,"auto");
    char *line=NULL;size_t cap=0;ssize_t len;int rc=0,ln=0;
    /* Read globals first, preserving the existing order-independent format. */
    while((len=getline(&line,&cap,f))>=0){ln++;if(len>=MAX_LINE||memchr(line,0,(size_t)len)){rc=cfg_error(ln,"設定行過長或包含 NUL");break;}
        char *s=cfg_trim(line),*v=strchr(s,'=');if(!v||*s=='#')continue;*v++=0;bool ok=true;
        if(!strcmp(s,"partition"))ok=cfg_copy(c->partition,sizeof(c->partition),v);
        if(!strcmp(s,"mount_point"))ok=cfg_copy(c->mp,sizeof(c->mp),v);
        if(!strcmp(s,"fs"))ok=cfg_copy(c->fs,sizeof(c->fs),v);
        if(!strcmp(s,"vendor_gallery_quiesce"))ok=cfg_copy(c->quiesce,sizeof(c->quiesce),v);
        if(!ok){rc=cfg_error(ln,"全域欄位過長");break;}
    }
    if(!rc&&(!cfg_id(c->partition)||!cfg_path(c->mp,true)))rc=cfg_error(0,"partition 或 mount_point 無效/未填寫");
    if(!rc&&strcmp(c->fs,"auto")&&strcmp(c->fs,"ext4")&&strcmp(c->fs,"f2fs"))rc=cfg_error(0,"fs 只接受 auto/f2fs/ext4");
    if(!rc&&strcmp(c->quiesce,"auto")&&strcmp(c->quiesce,"off")&&strcmp(c->quiesce,"force"))rc=cfg_error(0,"vendor_gallery_quiesce 只接受 auto/off/force");
    rewind(f);ln=0;
    while(!rc&&!global&&(len=getline(&line,&cap,f))>=0){
        ln++;if(len>=MAX_LINE||memchr(line,0,(size_t)len)){rc=cfg_error(ln,"設定行過長或包含 NUL");break;}char *s=cfg_trim(line);if(!*s||*s=='#')continue;char *value=strchr(s,'=');if(!value){rc=cfg_error(ln,"不支援的設定");break;}*value++=0;
        if(!strcmp(s,"version")||!strcmp(s,"partition")||!strcmp(s,"mount_point")||!strcmp(s,"fs")||!strcmp(s,"vendor_gallery_quiesce"))continue;
        char *v[11]={0};int n=cfg_fields(value,v,11);
        if(!strcmp(s,"profile")){
            if(n!=2||c->np==MAX_ROWS||!cfg_id(v[0])||!cfg_id(v[1])||cfg_selected(c,v[0])){rc=cfg_error(ln,"profile 名稱無效或重複 profile group");break;}
            CfgProfile *p=&c->profiles[c->np++];if(!cfg_copy(p->group,sizeof(p->group),v[0])||!cfg_copy(p->value,sizeof(p->value),v[1]))rc=cfg_error(ln,"profile 欄位過長");
        }else if(!strcmp(s,"dir")){
            if(n!=2||c->nd==MAX_ROWS||(strcmp(v[1],"preserve")&&strcmp(v[1],"media_rw"))){rc=cfg_error(ln,"dir 格式或 policy 無效");break;}
            CfgDir *d=&c->dirs[c->nd++];if(!cfg_source(c->mp,v[0],d->path,sizeof(d->path)))rc=cfg_error(ln,"dir 路徑無效/含 traversal");else strcpy(d->policy,v[1]);
        }else if(!strcmp(s,"mount")){
            if(n<8||n>10||c->mounts.count==MAX_ROWS){rc=cfg_error(ln,"mount 必須有 8~10 個欄位，最多 96 筆");break;}
            Row *r=&c->mounts.rows[c->mounts.count++];
            if(!parse_int_field(v[1],&r->user)||!cfg_user(r->user,users)){rc=cfg_error(ln,"user 無效或不存在");break;}
            if(!cfg_source(c->mp,v[2],r->src,sizeof(r->src))||!cfg_target(r->user,v[3],r->lower,r->visible)){rc=cfg_error(ln,"來源或 target 路徑無效/含 traversal，或 User ID 不一致");break;}
            if(!parse_int_field(v[4],&r->enabled)||r->enabled>1){rc=cfg_error(ln,"enabled 只能是 0/1");break;}
            const char *policy=*v[7]?v[7]:"preserve",*create=n>=9&&*v[8]?v[8]:"0",*migrate=n>=10&&*v[9]?v[9]:"none";
            if(strcmp(policy,"preserve")&&strcmp(policy,"media_rw")&&strcmp(policy,"bindfs_shared")){rc=cfg_error(ln,"policy 無效");break;}
            if(!parse_int_field(create,&r->create)||r->create>1||(strcmp(migrate,"none")&&strcmp(migrate,"once"))){rc=cfg_error(ln,"create 或 migrate 無效");break;}
            if((*v[5]||*v[6])&&(!cfg_id(v[5])||!cfg_id(v[6]))){rc=cfg_error(ln,"profile group/value 無效");break;}
            char a[PATH_MAX],b[PATH_MAX];const char *ra=realpath(r->src,a)?a:r->src,*rb=realpath(r->lower,b)?b:r->lower;
            if(!strcmp(ra,rb)){rc=cfg_error(ln,"來源與目標實體路徑不可相同");break;}
            const char *target=*v[3]=='/'?v[3]:r->visible;char name[PATH_MAX];snprintf(name,sizeof(name),"%s",target);size_t z=strlen(name);if(z&&name[z-1]=='/')name[z-1]=0;const char *base=strrchr(name,'/');base=base?base+1:name;
            if(!cfg_copy(r->name,sizeof(r->name),*v[0]?v[0]:base)||!cfg_copy(r->target,sizeof(r->target),target)||!cfg_copy(r->group,sizeof(r->group),v[5])||!cfg_copy(r->profile,sizeof(r->profile),v[6])){rc=cfg_error(ln,"mount 欄位過長");break;}
            for(const unsigned char *q=(const unsigned char *)r->name;*q;q++)if(*q<32||*q==127){rc=cfg_error(ln,"名稱包含控制字元");break;}
            strcpy(r->policy,policy);strcpy(r->migrate,migrate);
        }else rc=cfg_error(ln,"不支援的設定");
    }
    if(ferror(f)&&!rc)rc=2;free(line);fclose(f);
    for(int i=0;i<c->mounts.count&&!rc;i++){
        Row *r=&c->mounts.rows[i];if(!r->enabled)continue;const char *s=*r->group?cfg_selected(c,r->group):NULL;
        if(*r->group&&!s){rc=cfg_error(0,"profile group 沒有 profile=... 選擇值");break;}
        if(s&&strcmp(s,r->profile))continue;
        for(int j=0;j<i;j++){Row *p=&c->mounts.rows[j];const char *v=*p->group?cfg_selected(c,p->group):NULL;
            if(p->enabled&&(!*p->group||(v&&!strcmp(v,p->profile)))&&r->user==p->user&&!strcmp(r->lower,p->lower)){rc=cfg_error(0,"目前 profile 選擇造成重複 target，拒絕套用");rc=4;break;}}
    }
    if(!rc)rc=cfg_publish(c,out,global);free(c);return rc;
}
static int config_main(int argc,char **argv){
    if(argc<2||strcmp(argv[1],"parse-config"))return -1;
    if(argc!=7||(strcmp(argv[6],"all")&&strcmp(argv[6],"global")))return 2;
    g_opt.log_path=argv[4];return config_parse(argv[2],argv[3],argv[5],!strcmp(argv[6],"global"));
}
