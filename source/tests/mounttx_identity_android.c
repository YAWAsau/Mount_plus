#define main mounttx_program_main
#include "../mounttx.c"
#undef main
#include <assert.h>

int main(int argc,char **argv) {
    assert(argc==2 && strncmp(argv[1],"/data/local/tmp/yaw1493-native-",29)==0);
    assert(unshare(CLONE_NEWNS)==0);
    assert(mount(NULL,"/",NULL,MS_REC|MS_PRIVATE,NULL)==0);
    assert(chdir(argv[1])==0);
    assert(mkdir("src",0700)==0); assert(mkdir("dst",0700)==0);assert(mkdir("foreign",0700)==0);
    Row r={0}; r.user=0;
    snprintf(r.src,sizeof(r.src),"%s/src",argv[1]);
    snprintf(r.lower,sizeof(r.lower),"%s/dst",argv[1]);
    snprintf(r.visible,sizeof(r.visible),"%s/dst",argv[1]);
    strcpy(r.policy,"preserve");g_opt.runtime=argv[1];
    assert(mount(r.src,r.lower,NULL,MS_BIND,NULL)==0);
    struct stat st;assert(stat(r.src,&st)==0);
    FILE *f=fopen("active_source_state.tsv","w");assert(f);
    fprintf(f,"0|%s|%s|preserve|%llu:%llu\n",r.lower,r.src,(unsigned long long)st.st_dev,(unsigned long long)st.st_ino);fclose(f);
    assert(rmdir("src")==0);assert(mkdir("src",0700)==0);
    assert(!stat_same(r.src,r.lower));assert(saved_source_matches_lower(&r));
    assert(unmount_pid_if_ours(getpid(),&r)==0);assert(!is_any_mount_here(r.lower));
    assert(mount(r.src,r.lower,NULL,MS_BIND,NULL)==0);assert(stat_same(r.src,r.lower));
    assert(test_visible_once(&r));
    assert(umount2(r.lower,0)==0);
    char foreign[PATH_MAX];snprintf(foreign,sizeof(foreign),"%s/foreign",argv[1]);
    assert(mount(foreign,r.lower,NULL,MS_BIND,NULL)==0);
    assert(!saved_source_matches_lower(&r));assert(unmount_pid_if_ours(getpid(),&r)==0);
    assert(is_any_mount_here(r.lower));assert(umount2(r.lower,0)==0);
    assert(mount(r.src,r.src,NULL,MS_BIND,NULL)==0);
    assert(mount(NULL,r.src,NULL,MS_BIND|MS_REMOUNT|MS_RDONLY,NULL)==0);
    assert(!test_visible_once(&r));
    assert(umount2(r.src,0)==0);
    puts("PASS: replaced-source detach, remount identity, probe, foreign mount preserved, unwritable source fails closed");
    return 0;
}
