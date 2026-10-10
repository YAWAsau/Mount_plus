/* Watch source path identities, including absent ancestors. No periodic scan. */
#define _GNU_SOURCE
#include <sys/inotify.h>
#include <sys/stat.h>
#include <unistd.h>
#include <errno.h>
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>

typedef struct { char path[PATH_MAX]; dev_t dev; ino_t ino; int exists; } Source;
typedef struct { Source *rows; size_t n; } Snapshot;

static void watch_parents(int fd, const char *path) {
    char p[PATH_MAX];
    if (strlen(path) >= sizeof(p)) { errno=ENAMETOOLONG; perror("sourcewatch"); exit(2); }
    strcpy(p,path);
    for (;;) {
        char *slash=strrchr(p,'/');
        if (!slash) break;
        if (slash==p) p[1]=0; else *slash=0;
        if (inotify_add_watch(fd,p,IN_CREATE|IN_DELETE|IN_MOVED_FROM|IN_MOVED_TO|
              IN_DELETE_SELF|IN_MOVE_SELF|IN_ONLYDIR) < 0 && errno!=ENOENT && errno!=ENOTDIR) {
            perror("sourcewatch watch"); exit(3);
        }
        if (slash==p) break;
    }
}

static Snapshot snapshot(int fd,const char *file) {
    Snapshot s={0};
    if (fd>=0) {
        watch_parents(fd,file);
        if (inotify_add_watch(fd,file,IN_CLOSE_WRITE|IN_MODIFY|IN_DELETE_SELF|IN_MOVE_SELF)<0 && errno!=ENOENT && errno!=ENOTDIR) {
            perror("sourcewatch rows");exit(3);
        }
    }
    FILE *f=fopen(file,"r");
    if (!f) return s;
    char *line=NULL; size_t cap=0;
    while (getline(&line,&cap,f)>=0) {
        char *rest=line, *src=NULL;
        for (int i=0;i<3;i++) src=strsep(&rest,"|");
        if (!src || src[0]!='/' || strlen(src)>=PATH_MAX) continue;
        Source *rows=realloc(s.rows,(s.n+1)*sizeof(*rows));
        if (!rows) { perror("sourcewatch alloc"); exit(4); }
        s.rows=rows; Source *r=&s.rows[s.n++]; memset(r,0,sizeof(*r)); strcpy(r->path,src);
        if (fd>=0) {
            watch_parents(fd,src);
            char resolved[PATH_MAX];
            if (realpath(src,resolved) && strcmp(resolved,src)) watch_parents(fd,resolved);
        }
        struct stat st;
        if (stat(src,&st)==0 && S_ISDIR(st.st_mode)) { r->exists=1;r->dev=st.st_dev;r->ino=st.st_ino; }
    }
    free(line); fclose(f); return s;
}

static int changed(const Snapshot *old,const Snapshot *now) {
    for (size_t i=0;i<now->n;i++) {
        const Source *r=&now->rows[i]; if (!r->exists) continue;
        size_t j;
        for (j=0;j<old->n;j++) if (!strcmp(old->rows[j].path,r->path)) break;
        if (j==old->n || !old->rows[j].exists || old->rows[j].dev!=r->dev || old->rows[j].ino!=r->ino) return 1;
    }
    return 0;
}

int main(int argc,char **argv) {
    if (argc!=2 || argv[1][0]!='/') return 2;
    setvbuf(stdout,NULL,_IOLBF,0);
    Snapshot previous={0}; int fd=-1;
    for (;;) {
        int next=inotify_init1(IN_CLOEXEC);
        if (next<0) { perror("sourcewatch init");return 3; }
        Snapshot current=snapshot(next,argv[1]);
        if (fd>=0) close(fd);
        fd=next;
        if (changed(&previous,&current)) puts("changed");
        free(previous.rows); previous=current;
        /* Events during watch installation remain queued; a second identity
           sample closes the race before blocking on the kernel event reader. */
        Snapshot check=snapshot(-1,argv[1]);
        int retry=changed(&previous,&check)||changed(&check,&previous);
        free(check.rows);
        if (retry) continue;
        char buf[65536] __attribute__((aligned(8)));
        ssize_t n;
        do { n=read(fd,buf,sizeof(buf)); } while (n<0 && errno==EINTR);
        if (n<=0) { perror("sourcewatch read");return 5; }
        /* Re-arm on every event, including overflow and ancestor replacement.
           Content writes below an existing source are deliberately not watched. */
    }
}
