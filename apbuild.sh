#!/bin/sh
# ==============================================================================
# FreeBSD 기반 GNOME/Nemo + Oh-My-Zsh + Flatpak + Rust(uutils) + Fcitx5 한글 빌드 스크립트
# ==============================================================================

set -e

# [0-1] root 권한 체크
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 에러: 이 스크립트는 반드시 root 권한(sudo)으로 실행해야 합니다."
    exit 1
fi

DISTRO_NAME="ALPHAPRESS"
TIMESTAMP=$(date +%s)

WORK_DIR="/tmp/alphapress_build_${TIMESTAMP}"
ISO_OUT_DIR="/tmp/alphapress_out_${TIMESTAMP}"
ISO_PATH="${ISO_OUT_DIR}/${DISTRO_NAME}-Desktop.iso"

GNOME_CORE="x11/gnome-shell x11/gdm x11-wm/mutter x11/gnome-menus x11/gnome-session \
            deskutils/gnome-calendar math/gnome-calculator deskutils/gnome-font-viewer \
            editors/gnome-text-editor deskutils/gnome-characters deskutils/gnome-weather \
            deskutils/gnome-clocks deskutils/gnome-maps graphics/gnome-screenshot \
            sysutils/gnome-control-center sysutils/gnome-settings-daemon sysutils/gnome-system-monitor"

PACKAGES="${GNOME_CORE} x11-themes/linux-mint-themes graphics/drm-kmod \
          audio/pipewire git shells/zsh sysutils/flatpak sysutils/uutils-coreutils \
          ftp/curl archivers/unzip x11/mate-terminal x11-filemanagers/nemo \
          textproc/fcitx5 textproc/fcitx5-hangul textproc/fcitx5-configtool \
          textproc/fcitx5-qt textproc/fcitx5-gtk x11/xkeyboard-config"

echo "=== [0-2] 기존 유령 마운트 및 좀비 자원 강제 처단 ==="
sysctl kern.securelevel=-1 2>/dev/null || true

for old_dir in /tmp/alphapress_build*; do
    if [ -d "${old_dir}" ]; then
        fuser -kx "${old_dir}" 2>/dev/null || true
        umount -f "${old_dir}/rootfs/compat/linux/proc" 2>/dev/null || true
        umount -f "${old_dir}/rootfs/proc" 2>/dev/null || true
        umount -f "${old_dir}/rootfs/dev" 2>/dev/null || true
        chflags -R noschg,nougchg,nosappnd,nouappnd "${old_dir}" 2>/dev/null || true
        rm -rf "${old_dir}" 2>/dev/null || true
    fi
done

sysrc linux_enable="YES" >/dev/null 2>&1 || true
kldload linux 2>/dev/null || true
kldload linprocfs 2>/dev/null || true

echo "=== [1/6] 청정 격리 빌드 디렉토리 초기화 및 Base 동기화 ==="
mkdir -p "${WORK_DIR}/rootfs" "${ISO_OUT_DIR}"

tar -cf - -C / \
    --exclude=proc \
    --exclude=dev \
    --exclude=tmp \
    boot bin sbin lib libexec etc \
    usr/bin usr/sbin usr/lib usr/libexec | \
    tar -xf - -C "${WORK_DIR}/rootfs"

mkdir -p \
    "${WORK_DIR}/rootfs/dev" \
    "${WORK_DIR}/rootfs/proc" \
    "${WORK_DIR}/rootfs/root" \
    "${WORK_DIR}/rootfs/tmp" \
    "${WORK_DIR}/rootfs/var/db/pkg" \
    "${WORK_DIR}/rootfs/var/cache/pkg" \
    "${WORK_DIR}/rootfs/var/run" \
    "${WORK_DIR}/rootfs/var/log"

chmod 1777 "${WORK_DIR}/rootfs/tmp"

echo "=== [2/6] 기본 패키지 및 폰트/의존성 일괄 원격 다운로드 ==="

# DNS 설정 복사
cp /etc/resolv.conf "${WORK_DIR}/rootfs/etc/"

# pkg 저장소 및 키 디렉토리 생성
mkdir -p "${WORK_DIR}/rootfs/etc/pkg"
mkdir -p "${WORK_DIR}/rootfs/usr/share/keys/pkg/trusted"
mkdir -p "${WORK_DIR}/rootfs/usr/share/keys/pkg/revoked"
mkdir -p "${WORK_DIR}/rootfs/usr/local/etc"
mkdir -p "${WORK_DIR}/rootfs/var/db/pkg"
mkdir -p "${WORK_DIR}/rootfs/var/cache/pkg"

# 호스트의 pkg 키 복사
if [ -d "/usr/share/keys/pkg" ]; then
    cp -R /usr/share/keys/pkg/ "${WORK_DIR}/rootfs/usr/share/keys/"
fi

# 호스트 ABI 및 OSVERSION 자동 감지
HOST_ABI=$(pkg config ABI 2>/dev/null || echo "FreeBSD:15:amd64")
HOST_OSVERSION=$(sysctl -n kern.osreldate 2>/dev/null || echo "1500000")
echo "-> 감지된 호스트 ABI: ${HOST_ABI}"
echo "-> 감지된 호스트 OSVERSION: ${HOST_OSVERSION}"

# pkg.conf 에 ABI와 OSVERSION을 명시적으로 고정
cat > "${WORK_DIR}/rootfs/usr/local/etc/pkg.conf" << PKGEOF
ABI = "${HOST_ABI}";
OSVERSION = ${HOST_OSVERSION};
REPOS_DIR = ["/etc/pkg/"];
PKG_DBDIR = "/var/db/pkg";
PKG_CACHEDIR = "/var/cache/pkg";
PKGEOF

echo "-> 설정된 pkg.conf 확인:"
cat "${WORK_DIR}/rootfs/usr/local/etc/pkg.conf"

# 저장소 설정 파일 작성
cat > "${WORK_DIR}/rootfs/etc/pkg/FreeBSD.conf" << NETEOF
FreeBSD: {
  url: "https://pkg.freebsd.org/${HOST_ABI}/latest",
  mirror_type: "none",
  signature_type: "fingerprints",
  fingerprints: "/usr/share/keys/pkg",
  enabled: yes
}
NETEOF

echo "-> 설정된 저장소 URL 확인:"
cat "${WORK_DIR}/rootfs/etc/pkg/FreeBSD.conf"

# 호스트 환경변수 간섭 완전 차단
unset ABI
unset CLEAN_ABI
unset PKG_DBDIR
unset PKG_CACHEDIR

echo "-> 패키지 리포지토리 카탈로그 강제 동기화 진행..."
pkg -c "${WORK_DIR}/rootfs" update -f

echo "-> 데스크톱 컴포넌트 일괄 원격 설치 진행 중..."
pkg -c "${WORK_DIR}/rootfs" install -y ${PACKAGES}


echo "=== [3/6] Oh-My-Zsh 설치 및 'bira' 테마 전역 디폴트 적용 ==="
SKEL_DIR="${WORK_DIR}/rootfs/usr/share/skel"
mkdir -p "${SKEL_DIR}"

git clone --depth 1 https://github.com/ohmyzsh/ohmyzsh.git "${SKEL_DIR}/.oh-my-zsh"

cat << 'EOF' > "${SKEL_DIR}/.zshrc"
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="bira"
plugins=(git)
source $ZSH/oh-my-zsh.sh
EOF

cp "${SKEL_DIR}/.zshrc" "${WORK_DIR}/rootfs/root/.zshrc"
cp -R "${SKEL_DIR}/.oh-my-zsh" "${WORK_DIR}/rootfs/root/.oh-my-zsh"

sed -i '' 's|/bin/csh|/usr/local/bin/zsh|g' "${WORK_DIR}/rootfs/etc/master.passwd"
pwd_mkdb -d "${WORK_DIR}/rootfs/etc" "${WORK_DIR}/rootfs/etc/master.passwd"


echo "=== [4/6] 오픈소스 Hatter 아이콘 실시간 클론 및 이식 ==="
mkdir -p "${WORK_DIR}/rootfs/usr/local/share/icons"

git clone --depth 1 https://github.com/Mibea/Hatter.git "${WORK_DIR}/tmp_hatter"

HATTER_DIR="${WORK_DIR}/rootfs/usr/local/share/icons/Hatter"

if [ -d "${WORK_DIR}/tmp_hatter/Hatter" ]; then
    mv "${WORK_DIR}/tmp_hatter/Hatter" "${HATTER_DIR}"
else
    mv "${WORK_DIR}/tmp_hatter" "${HATTER_DIR}"
fi

rm -rf "${WORK_DIR}/tmp_hatter" 2>/dev/null || true
echo "-> Hatter 아이콘 설치 완료: ${HATTER_DIR}"


echo "=== [4-2/6] Pretendard 및 D2Coding 폰트 다운로드 및 시스템 글꼴 등록 ==="

PRETENDARD_DIR="${WORK_DIR}/rootfs/usr/local/share/fonts/Pretendard"
mkdir -p "${PRETENDARD_DIR}"
curl -L -o "${WORK_DIR}/Pretendard.zip" \
    "https://github.com/orioncactus/pretendard/releases/latest/download/Pretendard-1.3.9.zip" \
    || echo "⚠️  Pretendard 다운로드 실패"

if [ -f "${WORK_DIR}/Pretendard.zip" ]; then
    unzip -q "${WORK_DIR}/Pretendard.zip" -d "${WORK_DIR}/pretendard_extracted" || true
    find "${WORK_DIR}/pretendard_extracted" -name "*.ttf" \
        -exec cp {} "${PRETENDARD_DIR}/" \; 2>/dev/null || true
    rm -rf "${WORK_DIR}/Pretendard.zip" "${WORK_DIR}/pretendard_extracted"
fi

D2CODING_DIR="${WORK_DIR}/rootfs/usr/local/share/fonts/D2Coding"
mkdir -p "${D2CODING_DIR}"
curl -L -o "${WORK_DIR}/D2Coding.zip" \
    "https://github.com/naver/d2codingfont/releases/latest/download/D2Coding-Ver1.3.2-20180524.zip" \
    || echo "⚠️  D2Coding 다운로드 실패"

if [ -f "${WORK_DIR}/D2Coding.zip" ]; then
    unzip -q "${WORK_DIR}/D2Coding.zip" -d "${WORK_DIR}/d2coding_extracted" || true
    find "${WORK_DIR}/d2coding_extracted" -name "*.ttf" \
        -exec cp {} "${D2CODING_DIR}/" \; 2>/dev/null || true
    rm -rf "${WORK_DIR}/D2Coding.zip" "${WORK_DIR}/d2coding_extracted"
fi

mount -t devfs devfs "${WORK_DIR}/rootfs/dev"
chroot "${WORK_DIR}/rootfs" fc-cache -f -v 2>/dev/null || true
umount "${WORK_DIR}/rootfs/dev"


echo "=== [5/6] 시스템 런타임 설정 (MATE-Terminal, Nemo, uutils, Fcitx5 한글 프리셋) ==="

cat << 'EOF' > "${WORK_DIR}/rootfs/etc/rc.conf"
hostname="alphapress"
zfs_enable="YES"
dtraceall_enable="YES"
dbus_enable="YES"
gdm_enable="YES"
avahi_daemon_enable="YES"
kld_list="i915kms amdgpu"
EOF

cat << 'EOF' > "${WORK_DIR}/rootfs/etc/profile"
export LANG=ko_KR.UTF-8
export LC_ALL=ko_KR.UTF-8
export XMODIFIERS="@im=fcitx"
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
EOF

cat << 'EOF' >> "${SKEL_DIR}/.zshrc"
export LANG=ko_KR.UTF-8
export LC_ALL=ko_KR.UTF-8
export XMODIFIERS="@im=fcitx"
export GTK_IM_MODULE=fcitx
export QT_IM_MODULE=fcitx
EOF
cp "${SKEL_DIR}/.zshrc" "${WORK_DIR}/rootfs/root/.zshrc"

cat << 'EOF' > "${WORK_DIR}/rootfs/boot/loader.conf"
dtraceall_load="YES"
autoboot_delay="2"
EOF

cat << 'EOF' > "${WORK_DIR}/rootfs/etc/fstab"
proc                /proc           procfs  rw              0       0
linprocfs           /compat/linux/proc linprocfs rw          0       0
EOF
mkdir -p "${WORK_DIR}/rootfs/compat/linux/proc"

cat << 'EOF' > "${WORK_DIR}/rootfs/etc/rc.local"
#!/bin/sh
flatpak remote-add --if-not-exists flathub https://flathub.org/repo/flathub.flatpakrepo
flatpak install -y flathub io.github.kolunmi.Bazaar
flatpak install -y flathub io.github.mclab7.MissionCenter
ln -sf /var/lib/flatpak/exports/share/applications/* /usr/local/share/applications/ 2>/dev/null || true
EOF
chmod +x "${WORK_DIR}/rootfs/etc/rc.local"

DCONF_DIR="${WORK_DIR}/rootfs/usr/local/etc/dconf/db/local.d"
mkdir -p "${DCONF_DIR}"
cat << 'EOF' > "${DCONF_DIR}/00-custom-theme"
[org/gnome/desktop/interface]
gtk-theme='Mint-Y'
icon-theme='Hatter'
cursor-theme='Adwaita'
font-name='Pretendard Regular 10'
document-font-name='Pretendard Regular 11'
monospace-font-name='D2Coding 10'

[org/gnome/desktop/applications/terminal]
exec='mate-terminal'

[org/gnome/desktop/background]
show-desktop-icons=false

[org/gnome/desktop/input-sources]
sources=[('xkb', 'kr+kr104')]
xkb-options=['korean:ralt_hangul', 'korean:rctrl_hanja']

[org/nemo/desktop]
show-desktop-icons=true
EOF

MIME_DIR="${WORK_DIR}/rootfs/usr/local/share/applications"
mkdir -p "${MIME_DIR}"
cat << 'EOF' > "${MIME_DIR}/mimeapps.list"
[Default Applications]
inode/directory=nemo.desktop
x-scheme-handler/file=nemo.desktop
EOF

mkdir -p "${WORK_DIR}/rootfs/usr/local/etc/dconf/profile"
cat << 'EOF' > "${WORK_DIR}/rootfs/usr/local/etc/dconf/profile/user"
user-db
local
EOF

mount -t devfs devfs "${WORK_DIR}/rootfs/dev" 2>/dev/null || true
chroot "${WORK_DIR}/rootfs" dconf update 2>/dev/null || true
umount "${WORK_DIR}/rootfs/dev" 2>/dev/null || true

mkdir -p "${WORK_DIR}/rootfs/usr/local/bin"
for cmd in ls cp mv rm mkdir rmdir cat echo chmod chown date test uname pwd whoami; do
    if [ -f "${WORK_DIR}/rootfs/usr/local/bin/uutils-${cmd}" ]; then
        ln -sf "uutils-${cmd}" "${WORK_DIR}/rootfs/usr/local/bin/${cmd}"
    elif [ -f "${WORK_DIR}/rootfs/usr/local/bin/uutils" ]; then
        ln -sf uutils "${WORK_DIR}/rootfs/usr/local/bin/${cmd}"
    fi
done


echo "=== [6/6] 불필요 파일 정리 및 부팅 하이브리드 ISO 컴파일 ==="
rm -f "${WORK_DIR}/rootfs/etc/resolv.conf"

pkg -c "${WORK_DIR}/rootfs" clean -y 2>/dev/null || true

umount -f "${WORK_DIR}/rootfs/dev" 2>/dev/null || true
umount -f "${WORK_DIR}/rootfs/proc" 2>/dev/null || true
umount -f "${WORK_DIR}/rootfs/compat/linux/proc" 2>/dev/null || true

echo "-> ISO 이미지 생성 중: ${ISO_PATH}"
makefs -t cd9660 \
    -o rockridge \
    -o label="${DISTRO_NAME}" \
    -o bootimage="i386;${WORK_DIR}/rootfs/boot/cdboot" \
    -o no-emul-boot \
    "${ISO_PATH}" \
    "${WORK_DIR}/rootfs"

echo "=============================================================================="
echo "🎉 Ultimate 데스크탑 배포판 ISO 빌드가 끝났습니다!"
echo "📍 생성된 파일 위치: ${ISO_PATH}"
echo "=============================================================================="
