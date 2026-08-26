typedef unsigned long usize;
typedef long isize;
typedef unsigned int u32;

#define SYS_inotify_init1 26
#define SYS_inotify_add_watch 27
#define SYS_close 57
#define SYS_read 63
#define SYS_write 64
#define SYS_exit 93
#define AT_FDCWD -100
#define IN_CLOEXEC 02000000
#define IN_NONBLOCK 00004000
#define IN_ACCESS        0x00000001
#define IN_MODIFY        0x00000002
#define IN_ATTRIB        0x00000004
#define IN_CLOSE_WRITE   0x00000008
#define IN_MOVED_FROM    0x00000040
#define IN_MOVED_TO      0x00000080
#define IN_CREATE        0x00000100
#define IN_DELETE        0x00000200
#define IN_DELETE_SELF   0x00000400
#define IN_MOVE_SELF     0x00000800
#define IN_IGNORED       0x00008000

struct inotify_event_local { int wd; u32 mask; u32 cookie; u32 len; char name[]; };

static inline long sc1(long n,long a){ register long x8 __asm__("x8")=n; register long x0 __asm__("x0")=a; __asm__ volatile("svc #0":"+r"(x0):"r"(x8):"memory"); return x0; }
static inline long sc2(long n,long a,long b){ register long x8 __asm__("x8")=n; register long x0 __asm__("x0")=a; register long x1 __asm__("x1")=b; __asm__ volatile("svc #0":"+r"(x0):"r"(x1),"r"(x8):"memory"); return x0; }
static inline long sc3(long n,long a,long b,long c){ register long x8 __asm__("x8")=n; register long x0 __asm__("x0")=a; register long x1 __asm__("x1")=b; register long x2 __asm__("x2")=c; __asm__ volatile("svc #0":"+r"(x0):"r"(x1),"r"(x2),"r"(x8):"memory"); return x0; }
static void xexit(int code){ sc1(SYS_exit,code); for(;;){} }
static usize slen(const char *s){usize n=0; while(s&&s[n])n++; return n;}
static int seq(const char*a,const char*b){usize i=0; if(!a||!b)return 0; while(a[i]&&b[i]&&a[i]==b[i])i++; return a[i]==0&&b[i]==0;}
static void puterr(const char*s){sc3(SYS_write,2,(long)s,(long)slen(s));}
static int split_path(const char *path,char *dir,usize dcap,char *base,usize bcap){
  usize n=slen(path), slash=(usize)-1, i; if(!n||n>=1024)return -1;
  for(i=0;i<n;i++) if(path[i]=='/') slash=i;
  if(slash==(usize)-1){ if(dcap<2||n+1>bcap)return -1; dir[0]='.';dir[1]=0; for(i=0;i<=n;i++)base[i]=path[i]; return 0; }
  if(slash==0){ if(dcap<2||n>bcap)return -1; dir[0]='/';dir[1]=0; for(i=slash+1;i<=n;i++)base[i-(slash+1)]=path[i]; return base[0]?0:-1; }
  if(slash+1>dcap || (n-slash)>bcap)return -1;
  for(i=0;i<slash;i++) dir[i]=path[i];
  dir[slash]=0;
  for(i=slash+1;i<=n;i++) base[i-(slash+1)]=path[i];
  return base[0]?0:-1;
}
static int wait_change(const char *path){
  char dir[1024], base[512], buf[8192];
  if(split_path(path,dir,sizeof(dir),base,sizeof(base))<0){puterr("confwatch: invalid path\n");return 2;}
  long fd=sc1(SYS_inotify_init1,IN_CLOEXEC); if(fd<0){puterr("confwatch: inotify_init1 failed\n");return 3;}
  u32 mask=IN_MODIFY|IN_ATTRIB|IN_CLOSE_WRITE|IN_MOVED_FROM|IN_MOVED_TO|IN_CREATE|IN_DELETE|IN_DELETE_SELF|IN_MOVE_SELF;
  long wd=sc3(SYS_inotify_add_watch,fd,(long)dir,mask); if(wd<0){sc1(SYS_close,fd);puterr("confwatch: inotify_add_watch failed\n");return 4;}
  for(;;){
    long r=sc3(SYS_read,fd,(long)buf,sizeof(buf)); if(r<=0){sc1(SYS_close,fd);return 5;}
    usize off=0; while(off+(usize)sizeof(struct inotify_event_local)<=(usize)r){
      struct inotify_event_local *ev=(struct inotify_event_local*)(buf+off);
      if(ev->mask&(IN_DELETE_SELF|IN_MOVE_SELF|IN_IGNORED)){sc1(SYS_close,fd);return 6;}
      if(ev->len && seq(ev->name,base) && (ev->mask&(IN_MODIFY|IN_ATTRIB|IN_CLOSE_WRITE|IN_MOVED_FROM|IN_MOVED_TO|IN_CREATE|IN_DELETE))){sc1(SYS_close,fd);return 0;}
      off += sizeof(struct inotify_event_local)+ev->len;
    }
  }
}
int main2(long argc,char **argv){
  if(argc==2 && seq(argv[1],"--version")){ sc3(SYS_write,1,(long)"confwatch 1.0.1-arm64-static64k-inmodify\n",41); return 0; }
  if(argc==3 && seq(argv[1],"--wait-change")) return wait_change(argv[2]);
  puterr("usage: confwatch --wait-change PATH\n"); return 2;
}
