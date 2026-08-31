typedef unsigned long usize;
typedef long isize;
typedef unsigned int u32;
typedef unsigned long long u64;

#define SYS_inotify_init1 26
#define SYS_inotify_add_watch 27
#define SYS_close 57
#define SYS_read 63
#define SYS_write 64
#define SYS_openat 56
#define SYS_ppoll 73
#define SYS_exit 93
#define AT_FDCWD -100
#define IN_CLOEXEC 02000000
#define IN_NONBLOCK 00004000
#define O_RDONLY 0
#define O_CLOEXEC 02000000
#define POLLIN 0x0001
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
struct pollfd_local { int fd; short events; short revents; };
struct timespec_local { long tv_sec; long tv_nsec; };

/* v1.4.79: freestanding -nostdlib build may still emit compiler builtin memcpy.
 * Provide tiny local memory routines so static no-libc confwatch links under NDK r28c. */
__attribute__((used)) void *memcpy(void *dst, const void *src, usize n){
  unsigned char *d=(unsigned char*)dst; const unsigned char *s=(const unsigned char*)src; usize i;
  for(i=0;i<n;i++) d[i]=s[i];
  return dst;
}
__attribute__((used)) void *memset(void *dst, int c, usize n){
  unsigned char *d=(unsigned char*)dst; usize i;
  for(i=0;i<n;i++) d[i]=(unsigned char)c;
  return dst;
}
__attribute__((used)) void *memmove(void *dst, const void *src, usize n){
  unsigned char *d=(unsigned char*)dst; const unsigned char *s=(const unsigned char*)src; usize i;
  if(d<s){ for(i=0;i<n;i++) d[i]=s[i]; }
  else if(d>s){ while(n){ n--; d[n]=s[n]; } }
  return dst;
}

static inline long sc1(long n,long a){ register long x8 __asm__("x8")=n; register long x0 __asm__("x0")=a; __asm__ volatile("svc #0":"+r"(x0):"r"(x8):"memory"); return x0; }
static inline long sc3(long n,long a,long b,long c){ register long x8 __asm__("x8")=n; register long x0 __asm__("x0")=a; register long x1 __asm__("x1")=b; register long x2 __asm__("x2")=c; __asm__ volatile("svc #0":"+r"(x0):"r"(x1),"r"(x2),"r"(x8):"memory"); return x0; }
static inline long sc4(long n,long a,long b,long c,long d){ register long x8 __asm__("x8")=n; register long x0 __asm__("x0")=a; register long x1 __asm__("x1")=b; register long x2 __asm__("x2")=c; register long x3 __asm__("x3")=d; __asm__ volatile("svc #0":"+r"(x0):"r"(x1),"r"(x2),"r"(x3),"r"(x8):"memory"); return x0; }
static inline long sc5(long n,long a,long b,long c,long d,long e){ register long x8 __asm__("x8")=n; register long x0 __asm__("x0")=a; register long x1 __asm__("x1")=b; register long x2 __asm__("x2")=c; register long x3 __asm__("x3")=d; register long x4 __asm__("x4")=e; __asm__ volatile("svc #0":"+r"(x0):"r"(x1),"r"(x2),"r"(x3),"r"(x4),"r"(x8):"memory"); return x0; }
static usize slen(const char *s){usize n=0; while(s&&s[n])n++; return n;}
static int seq(const char*a,const char*b){usize i=0; if(!a||!b)return 0; while(a[i]&&b[i]&&a[i]==b[i])i++; return a[i]==0&&b[i]==0;}
static void puterr(const char*s){sc3(SYS_write,2,(long)s,(long)slen(s));}
static void putout(const char*s){sc3(SYS_write,1,(long)s,(long)slen(s));}
static int split_path(const char *path,char *dir,usize dcap,char *base,usize bcap){
  usize n=slen(path), slash=(usize)-1, i; if(!n||n>=1024)return -1;
  for(i=0;i<n;i++) if(path[i]=='/') slash=i;
  if(slash==(usize)-1){ if(dcap<2||n+1>bcap)return -1; dir[0]='.';dir[1]=0; for(i=0;i<=n;i++)base[i]=path[i]; return 0; }
  if(slash==0){ if(dcap<2||n>bcap)return -1; dir[0]='/';dir[1]=0; for(i=slash+1;i<=n;i++)base[i-(slash+1)]=path[i]; return base[0]?0:-1; }
  if(slash+1>dcap || (n-slash)>bcap)return -1;
  for(i=0;i<slash;i++) dir[i]=path[i]; dir[slash]=0;
  for(i=slash+1;i<=n;i++) base[i-(slash+1)]=path[i];
  return base[0]?0:-1;
}

static void sleep_ms(long ms){
  struct timespec_local ts; ts.tv_sec=ms/1000; ts.tv_nsec=(ms%1000)*1000000L;
  sc5(SYS_ppoll,0,0,(long)&ts,0,0);
}

static int hash_to_str(u64 h,u64 n,char *out,usize cap){
  static const char hex[]="0123456789abcdef";
  usize p=0; int i; char dec[32]; usize d=0;
  if(cap<4)return -1;
  for(i=15;i>=0;i--){ if(p+1>=cap)return -1; out[p++]=hex[(h>>((unsigned)i*4))&15ULL]; }
  if(p+1>=cap)return -1; out[p++]=':';
  if(n==0){ if(p+2>=cap)return -1; out[p++]='0'; out[p]=0; return 0; }
  while(n && d<sizeof(dec)){ dec[d++]=(char)('0'+(n%10)); n/=10; }
  while(d){ if(p+1>=cap)return -1; out[p++]=dec[--d]; }
  out[p]=0; return 0;
}

static int file_hash(const char *path,char *out,usize cap){
  char buf[4096]; u64 h=1469598103934665603ULL; u64 n=0; long fd,r; usize i;
  fd=sc4(SYS_openat,AT_FDCWD,(long)path,O_RDONLY|O_CLOEXEC,0);
  if(fd<0)return -1;
  for(;;){
    r=sc3(SYS_read,fd,(long)buf,sizeof(buf));
    if(r<0){ sc1(SYS_close,fd); return -1; }
    if(r==0)break;
    for(i=0;i<(usize)r;i++){ h^=(unsigned char)buf[i]; h*=1099511628211ULL; }
    n+=(u64)r;
  }
  sc1(SYS_close,fd);
  return hash_to_str(h,n,out,cap);
}

static int drain_inotify(int fd,const char *base){
  char buf[8192]; int changed=0;
  for(;;){
    long r=sc3(SYS_read,fd,(long)buf,sizeof(buf));
    if(r<=0)break;
    usize off=0;
    while(off+(usize)sizeof(struct inotify_event_local)<=(usize)r){
      struct inotify_event_local *ev=(struct inotify_event_local*)(buf+off);
      if(ev->mask&(IN_DELETE_SELF|IN_MOVE_SELF|IN_IGNORED)) changed=1;
      if(ev->len && seq(ev->name,base) && (ev->mask&(IN_MODIFY|IN_ATTRIB|IN_CLOSE_WRITE|IN_MOVED_FROM|IN_MOVED_TO|IN_CREATE|IN_DELETE))) changed=1;
      off += sizeof(struct inotify_event_local)+ev->len;
    }
  }
  return changed;
}

static int open_watch_dir(const char *path,char *base,usize bcap){
  char dir[1024]; long fd,wd; u32 mask;
  if(split_path(path,dir,sizeof(dir),base,bcap)<0)return -1;
  fd=sc1(SYS_inotify_init1,IN_CLOEXEC|IN_NONBLOCK);
  if(fd<0)return -1;
  mask=IN_MODIFY|IN_ATTRIB|IN_CLOSE_WRITE|IN_MOVED_FROM|IN_MOVED_TO|IN_CREATE|IN_DELETE|IN_DELETE_SELF|IN_MOVE_SELF;
  wd=sc3(SYS_inotify_add_watch,fd,(long)dir,mask);
  if(wd<0){ sc1(SYS_close,fd); return -1; }
  return (int)fd;
}

static int wait_change_legacy(const char *path){
  char base[512]; int fd=open_watch_dir(path,base,sizeof(base));
  if(fd<0){puterr("confwatch: inotify_add_watch failed\n");return 4;}
  for(;;){
    struct pollfd_local pfd; pfd.fd=fd; pfd.events=POLLIN; pfd.revents=0;
    sc5(SYS_ppoll,(long)&pfd,1,0,0,0);
    if(drain_inotify(fd,base)){sc1(SYS_close,fd);return 0;}
  }
}

static int wait_stable_change(const char *path,const char *last){
  char base[512], cur[96], cand[96], out[96]; int fd, stable=0, have_cand=0;
  fd=open_watch_dir(path,base,sizeof(base));
  cand[0]=0;
  for(;;){
    long timeout=have_cand?60:250;
    if(fd>=0){
      struct pollfd_local pfd; struct timespec_local ts;
      pfd.fd=fd; pfd.events=POLLIN; pfd.revents=0;
      ts.tv_sec=timeout/1000; ts.tv_nsec=(timeout%1000)*1000000L;
      sc5(SYS_ppoll,(long)&pfd,1,(long)&ts,0,0);
      drain_inotify(fd,base);
    } else {
      sleep_ms(timeout);
      fd=open_watch_dir(path,base,sizeof(base));
    }
    if(file_hash(path,cur,sizeof(cur))<0)continue;
    if(last && last[0] && seq(cur,last)){ have_cand=0; stable=0; cand[0]=0; continue; }
    if(!have_cand || !seq(cur,cand)){ usize i; for(i=0;i<sizeof(cand);i++){ cand[i]=cur[i]; if(cur[i]==0)break; } have_cand=1; stable=1; continue; }
    stable++;
    if(stable>=2){ usize i; for(i=0;i<sizeof(out);i++){ out[i]=cur[i]; if(cur[i]==0)break; } putout(out); putout("\n"); if(fd>=0)sc1(SYS_close,fd); return 0; }
  }
}

int main2(long argc,char **argv){
  char h[96];
  if(argc==2 && seq(argv[1],"--version")){ putout("confwatch 1.1.1-arm64-native-stable-content-nolibc-memcpy\n"); return 0; }
  if(argc==3 && seq(argv[1],"--hash")){ if(file_hash(argv[2],h,sizeof(h))<0)return 1; putout(h); putout("\n"); return 0; }
  if(argc==3 && seq(argv[1],"--wait-change")) return wait_change_legacy(argv[2]);
  if(argc==4 && seq(argv[1],"--wait-stable-change")) return wait_stable_change(argv[2],argv[3]);
  puterr("usage: confwatch --hash PATH | --wait-change PATH | --wait-stable-change PATH LAST_HASH\n"); return 2;
}
