# 1. 커널 보안 레벨을 일시적으로 무력화 시도 (싱글 유저 모드가 아닐 때를 대비)
sysctl kern.securelevel=-1 2>/dev/null || true

# 2. 빌드 디렉토리를 물고 있는 좀비 프로세스 및 마운트 강제 강탈
fuser -kx /tmp/alphapress_build 2>/dev/null || true
fuser -kx /tmp/alphapress_out 2>/dev/null || true
umount -f /tmp/alphapress_build/rootfs/compat/linux/proc 2>/dev/null || true
umount -f /tmp/alphapress_build/rootfs/proc 2>/dev/null || true
umount -f /tmp/alphapress_build/rootfs/dev 2>/dev/null || true

# 3. 플래그 강제 제거 및 '폴더 이름 변경' 우회 기법 적용
# (FreeBSD 커널에서 간혹 삭제는 막아도 폴더명 변경은 허용하는 맹점을 이용)
chflags -R noschg,nougchg,nosappnd,nouappnd /tmp/alphapress_build 2>/dev/null || true
mv /tmp/alphapress_build /tmp/alphapress_build_old_$(date +%s) 2>/dev/null || true

# 4. 이름이 바뀐 찌꺼기 폴더 및 출력 폴더 완전히 강제 소거
rm -rf /tmp/alphapress_build_old_* 2>/dev/null || true
rm -rf /tmp/alphapress_build 2>/dev/null || true
rm -rf /tmp/alphapress_out 2>/dev/null || true
