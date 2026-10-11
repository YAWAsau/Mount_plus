#include <sys/file.h>
#include <poll.h>
/* Process records contain PID, starttime and boot ID, never PID alone. */
static bool watch_identity_native(pid_t pid,unsigned long long *start){
    char p[64],buf[4096];snprintf(p,sizeof(p),"/proc/%d/stat",pid);
    if(read_first_line(p,buf,sizeof(buf)))return false;char *s=strrchr(buf,')');if(!s||s[1]!=' ')return false;s+=2;
    if(*s=='Z'||*s=='X')return false;
    char *save=NULL,*field=strtok_r(s," ",&save);for(int i=3;field&&i<22;i++)field=strtok_r(NULL," ",&save);
    if(!field)return false;char *end;errno=0;*start=strtoull(field,&end,10);return !errno&&!*end;
}
static int watch_record_write(const char *path,pid_t pid){
    unsigned long long start;char boot[80],tmp[PATH_MAX];
    if(!watch_identity_native(pid,&start)||read_first_line("/proc/sys/kernel/random/boot_id",boot,sizeof(boot)))return 1;
    if(snprintf(tmp,sizeof(tmp),"%s.tmp.%d",path,getpid())>=(int)sizeof(tmp))return 1;
    int fd=open(tmp,O_WRONLY|O_CREAT|O_TRUNC|O_CLOEXEC|O_NOFOLLOW,0600);if(fd<0)return 1;
    int rc=dprintf(fd,"%d %llu %s\n",pid,start,boot)<0?1:0;if(close(fd))rc=1;if(!rc&&rename(tmp,path))rc=1;if(rc)unlink(tmp);return rc;
}
static bool watch_record_pid(const char *path,pid_t *pid){
    char line[256],saved[80],boot[80];unsigned long long start,now;int p=0;
    if(read_first_line(path,line,sizeof(line))||sscanf(line,"%d %llu %79s",&p,&start,saved)!=3||p<=1)return false;
    if(read_first_line("/proc/sys/kernel/random/boot_id",boot,sizeof(boot))||strcmp(boot,saved)||!watch_identity_native(p,&now)||now!=start)return false;
    *pid=p;return true;
}
static int watch_record_signal(const char *path,bool group){
    pid_t pid;if(!watch_record_pid(path,&pid))return 0;
    /* Only a session leader can own a worker group. */
    if(group&&getpgid(pid)==pid) return kill(-pid,SIGTERM)&&errno!=ESRCH?1:0;
    return kill(pid,SIGTERM)&&errno!=ESRCH?1:0;
}
static volatile sig_atomic_t watch_stopping;
static void watch_stop_signal(int sig){(void)sig;watch_stopping=1;}
static bool watch_name(const char *n){return !strcmp(n,"confwatch")||!strcmp(n,"sourcewatch")||!strcmp(n,"userstate")||!strcmp(n,"user0prop")||!strcmp(n,"user0file");}
static void watch_delay(int ms){
    struct timespec until,now;clock_gettime(CLOCK_MONOTONIC,&until);until.tv_sec+=ms/1000;until.tv_nsec+=(ms%1000)*1000000L;if(until.tv_nsec>=1000000000L){until.tv_sec++;until.tv_nsec-=1000000000L;}
    while(!watch_stopping){clock_gettime(CLOCK_MONOTONIC,&now);long left=(until.tv_sec-now.tv_sec)*1000+(until.tv_nsec-now.tv_nsec)/1000000;if(left<=0)break;poll(NULL,0,(int)left);}
}
static int watch_supervisor(const char *mod,const char *runtime,const char *stop,const char *name){
    if(!watch_name(name))return 2;
    char lock[PATH_MAX],record[PATH_MAX],worker[PATH_MAX],done[PATH_MAX],pidfile[PATH_MAX],script[PATH_MAX],log[PATH_MAX],boot[80],prev[80];
    if(strlen(runtime)>PATH_MAX-128||strlen(mod)>PATH_MAX-32)return 2;
    snprintf(lock,sizeof(lock),"%s/watch.%s.lock",runtime,name);snprintf(record,sizeof(record),"%s/watch.%s.supervisor",runtime,name);
    snprintf(worker,sizeof(worker),"%s/watch.%s.worker",runtime,name);snprintf(done,sizeof(done),"%s/watch.%s.done",runtime,name);
    snprintf(pidfile,sizeof(pidfile),"%s/%s.pid",runtime,name);snprintf(script,sizeof(script),"%s/service.sh",mod);snprintf(log,sizeof(log),"%s/service.log",runtime);g_opt.log_path=log;
    int fd=open(lock,O_WRONLY|O_CREAT|O_CLOEXEC|O_NOFOLLOW,0600);if(fd<0)return 1;if(flock(fd,LOCK_EX|LOCK_NB)){close(fd);return 0;}
    bool once=!strcmp(name,"user0prop")||!strcmp(name,"user0file");
    if(read_first_line("/proc/sys/kernel/random/boot_id",boot,sizeof(boot))){close(fd);return 1;}
    if(!access(stop,F_OK)||(once&&!read_first_line(done,prev,sizeof(prev))&&!strcmp(boot,prev))){close(fd);return 0;}
    struct sigaction sa={0};sa.sa_handler=watch_stop_signal;sigemptyset(&sa.sa_mask);sigaction(SIGTERM,&sa,NULL);sigaction(SIGINT,&sa,NULL);signal(SIGHUP,SIG_IGN);
    watch_record_signal(worker,true);pid_t old;
    for(int i=0;i<40&&watch_record_pid(worker,&old)&&!watch_stopping;i++)watch_delay(50);
    if(watch_record_pid(worker,&old)||watch_stopping){close(fd);return 1;}
    if(watch_record_write(record,getpid())){close(fd);return 1;}
    FILE *pf=fopen(pidfile,"w");if(pf){fprintf(pf,"%d\n",getpid());fclose(pf);}
    int delay=1;log_msg("資訊","native supervisor start｜name=%s",name);
    while(!watch_stopping&&access(stop,F_OK)){
        unlink(worker);struct timespec start,end;clock_gettime(CLOCK_MONOTONIC,&start);
        /* Block stop signals across fork/setsid, so a newly born child cannot escape. */
        sigset_t block,prior;sigemptyset(&block);sigaddset(&block,SIGTERM);sigaddset(&block,SIGINT);sigprocmask(SIG_BLOCK,&block,&prior);
        pid_t child=fork();
        if(!child){close(fd);setsid();signal(SIGTERM,SIG_DFL);signal(SIGINT,SIG_DFL);sigprocmask(SIG_SETMASK,&prior,NULL);
            if(!access("/data/adb/ksu/bin/busybox",X_OK)){setenv("ASH_STANDALONE","1",1);execl("/data/adb/ksu/bin/busybox","busybox","sh",script,"--watcher",name,(char *)NULL);}
            execl("/system/bin/sh","sh",script,"--watcher",name,(char *)NULL);_exit(127);
        }
        sigprocmask(SIG_SETMASK,&prior,NULL);
        if(child<0){log_msg("錯誤","fork failed｜name=%s",name);watch_delay(delay*1000);delay=delay<15?delay*2:30;continue;}
        int status=0;pid_t w;
        for(;;){
            if(watch_stopping){if(getpgid(child)==child)kill(-child,SIGTERM);kill(child,SIGTERM);}
            w=waitpid(child,&status,0);if(w==child|| (w<0&&errno!=EINTR))break;
        }
        /* A pipe child may outlive its reader. Transactions use a separate session. */
        kill(-child,SIGTERM);
        if(watch_stopping)break;
        if(w==child&&WIFEXITED(status)&&WEXITSTATUS(status)==0&&once){FILE *f=fopen(done,"w");if(f){fprintf(f,"%s\n",boot);fclose(f);}break;}
        unlink(worker);clock_gettime(CLOCK_MONOTONIC,&end);if(end.tv_sec-start.tv_sec>=60)delay=1;
        log_msg("警告","native worker exit｜name=%s｜status=%d｜delay=%d",name,status,delay);
        watch_delay(delay*1000);delay=delay<15?delay*2:30;
    }
    unlink(worker);unlink(record);unlink(pidfile);close(fd);log_msg("資訊","native supervisor stop｜name=%s",name);return 0;
}
static int watch_main(int argc,char **argv){
    if(argc<2)return -1;
    if(!strcmp(argv[1],"watch-supervise")){if(argc!=6)return 2;return watch_supervisor(argv[2],argv[3],argv[4],argv[5]);}
    if(!strcmp(argv[1],"watch-live")){pid_t p;return argc==3&&watch_record_pid(argv[2],&p)?0:1;}
    if(!strcmp(argv[1],"watch-write")){int p;if(argc!=4||!parse_int_field(argv[3],&p)||p<=1)return 2;return watch_record_write(argv[2],p);}
    if(!strcmp(argv[1],"watch-signal")){if(argc!=4)return 2;return watch_record_signal(argv[2],!strcmp(argv[3],"group"));}
    if(!strcmp(argv[1],"watch-identity")){int p;unsigned long long start;if(argc!=3||!parse_int_field(argv[2],&p)||!watch_identity_native(p,&start))return 1;printf("%llu\n",start);return 0;}
    return -1;
}
