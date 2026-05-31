#!/bin/sh
# ==============================================================================
# FreeBSD 기반 ALPHAPRESS 빌드 환경 및 잔재 파일 일괄 제거 스크립트
# ==============================================================================

set -e

# 루트 권한 체크
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 에러: 이 스크립트는 반드시 root 권한(sudo)으로 실행해야 합니다."
    exit 1
fi

WORK_DIR="/tmp/alphapress_build"
ISO_OUT_DIR="/tmp/alphapress_out"

echo "=== [1/3] 가상 파일 시스템 마운트 해제 점검 ==="
# 혹시 chroot 내부 프로세스나 마운트가 꼬여서 남아있는지 확인 후 해제
for mnt in "${WORK_DIR}/rootfs/compat/linux/proc" "${WORK_DIR}/rootfs/proc" "${WORK_DIR}/rootfs/dev"; do
    if mount | grep -q "${mnt}"; then
        echo "-> 마운트 해제 중: ${mnt}"
        umount -f "${mnt}" || true
    fi
done

echo "=== [2/3] 파일 시스템 보호 플래그(chflags) 강제 해제 ==="
# FreeBSD 특유의 시스템 파일 보호 속성(schg, uarch 등)이 걸려있으면 rm이 실패하므로 플래그를 모두 지웁니다.
if [ -d "${WORK_DIR}" ]; then
    echo "-> ${WORK_DIR} 내부 파일 플래그 초기화 중..."
    chflags -R noschg,nougchg,nosappnd,nouappnd "${WORK_DIR}" 2>/dev/null || true
fi

if [ -d "${ISO_OUT_DIR}" ]; then
    echo "-> ${ISO_OUT_DIR} 내부 파일 플래그 초기화 중..."
    chflags -R noschg,nougchg,nosappnd,nouappnd "${ISO_OUT_DIR}" 2>/dev/null || true
fi

echo "=== [3/3] 빌드 및 출력 디렉토리 완전 삭제 ==="
if [ -d "${WORK_DIR}" ]; then
    echo "-> 임시 빌드 디렉토리 삭제 중..."
    rm -rf "${WORK_DIR}"
fi

if [ -d "${ISO_OUT_DIR}" ]; then
    echo "-> ISO 출력 디렉토리 삭제 중..."
    rm -rf "${ISO_OUT_DIR}"
fi

echo "=============================================================================="
echo "✨ ALPHAPRESS 빌드 환경이 완벽하게 초기화되었습니다!"
echo "🚀 이제 메인 빌드 스크립트를 안심하고 다시 실행하셔도 됩니다."
echo "=============================================================================="
