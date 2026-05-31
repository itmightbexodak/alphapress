#!/bin/sh
# ==============================================================================
# FreeBSD 기반 GNOME/Nemo + Oh-My-Zsh + Flatpak + Rust(uutils) + Fcitx5 한글 빌드 스크립트
# (오류 자동 복구, 프로세스 처단, 플래그 해제, 리눅스 커널 로드, ABI 동기화 내장형)
# ==============================================================================

set -e

# [0-1] root 권한 체크
if [ "$(id -u)" -ne 0 ]; then
    echo "❌ 에러: 이 스크립트는 반드시 root 권한(sudo)으로 실행해야 합니다."
    exit 1
fi

DISTRO_NAME="ALPHAPRESS"
WORK_DIR="/tmp/alphapress_build"
ISO_OUT_DIR="/tmp/alphapress_out"
ISO_PATH="${ISO_OUT_DIR}/${DISTRO_NAME}-Desktop.iso"

# [패키지 정밀 제어] 게임, Nautilus, gnome-console만 제외하고 필수 GNOME 앱은 유지
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

echo "=== [0-2] 실행 직전 체크리스트 및 좀비 환경 강제 소거 ==="
# 1. 이전 빌드 실패로 인해 핸들을 쥐고 있는 Chroot 내부 좀비 프로세스 사살
fuser -kx "${WORK_DIR}" 2>/dev/null || true

# 2. 잔여 가상 파일 시스템 강제 마운트 해제
umount -f "${WORK_DIR}/rootfs/compat/linux/proc" 2>/dev/null || true
umount -f "${WORK_DIR}/rootfs/proc" 2>/dev/null || true
umount -f "${WORK_DIR}/rootfs/dev" 2>/dev/null || true

# 3. FreeBSD 시스템 불변 플래그(schg, uchg 등) 해제하여 Operation not permitted 방지
if [ -d "${WORK_DIR}" ]; then
    echo "-> 기존 빌드 폴더의 시스템 불변 잠금 플래그 해제 중..."
    chflags -R noschg,nougchg,nosappnd,nouappnd "${WORK_DIR}" 2>/dev/null || true
fi
if [ -d "${ISO_OUT_DIR}" ]; then
    chflags -R noschg,nougchg,nosappnd,nouappnd "${ISO_OUT_DIR}" 2>/dev/null || true
fi

# 4. 호스트 OS 리눅스 바이너리 호환성 커널 모듈 활성화 (Flatpak 스택용)
echo "-> 호스트 커널 모듈(Linux/Linprocfs) 활성화 상태 점검 중..."
sysrc linux_enable="YES" >/dev/null 2>&1 || true
kldload linux 2>/dev/null || true
kldload linprocfs 2>/dev/null || true

echo "=== [1/6] 빌드 디렉토리 초기화 및 Base 동기화 ==="
rm -rf "${WORK_DIR}" "${ISO_OUT_DIR}"
mkdir -p "${WORK_DIR}/rootfs" "${ISO_OUT_DIR}"

tar -cf - -C / /boot /bin /sbin /lib /libexec /etc /usr/bin /usr/sbin /usr/lib /usr/libexec | tar -xf - -C "${WORK_DIR}/rootfs"
mkdir -p "${WORK_DIR}/rootfs/dev" "${WORK_DIR}/rootfs/proc" "${WORK_DIR}/rootfs/root" "${WORK_DIR}/rootfs/tmp" "${WORK_DIR}/rootfs/var"

echo "=== [2/6] 기본 패키지 및 폰트/의존성 일괄 원격 다운로드 ==="
cp /etc/resolv.conf "${WORK_DIR}/rootfs/etc/"

# [중요] 호스트의 공식pkg 저장소 구성을 내부 가상 환경으로 이식하여 주소 유실 원천 차단
mkdir -p "${WORK_DIR}/rootfs/etc/pkg"
if [ -f /etc/pkg/FreeBSD.conf ]; then
    cp /etc/pkg/FreeBSD.conf "${WORK_DIR}/rootfs/etc/pkg/"
fi
mkdir -p "${WORK_DIR}/rootfs/var/db/pkg"

# 호스트 커널의 정확한 ABI 환경변수를 강제 전달하여 No packages found 에러 타파
UNAME_r=$(uname -r)
export ABI="FreeBSD:${UNAME_r%%-*}:${ABI_ARCH:-$(uname -p)}"
echo "-> 패키지 리포지토리 강제 동기화 (Target ABI: ${ABI})..."
pkg -c "${WORK_DIR}/rootfs" update -f

echo "-> 패키지 일괄 설치 (Nautilus/Games/Console 제외)..."
pkg -c "${WORK_DIR}/rootfs" install -y ${PACKAGES}

echo "=== [3/6] Oh-My-Zsh 설치 및 'bira' 테마 전역 디폴트 적용 ==="
echo "-> 셸 환경 고도화 작업 중..."
SKEL_DIR="${WORK_DIR}/rootfs/usr/share/skel"
mkdir -p "${SKEL_DIR}"
git clone --depth 1 https://github.com "${SKEL_DIR}/.oh-my-zsh"

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
HATTER_DIR="${WORK_DIR}/rootfs/usr/local/share/icons/Hatter"
mkdir -p "${WORK_DIR}/rootfs/usr/local/share/icons"
git clone --depth 1 https://github.com "${WORK_DIR}/tmp_hatter"
mv "${WORK_DIR}/tmp_hatter/Hatter" "${HATTER_DIR}"
rm -rf "${WORK_DIR}/tmp_hatter"

echo "=== [4-2/6] Pretendard 및 D2Coding 폰트 다운로드 및 시스템 글꼴 등록 ==="
PRETENDARD_DIR="${WORK_DIR}/rootfs/usr/local/share/fonts/Pretendard"
mkdir -p "${PRETENDARD_DIR}"
curl -L -o "${WORK_DIR}/Pretendard.zip" "https://github.com"
unzip -q "${WORK_DIR}/Pretendard.zip" -d "${WORK_DIR}/pretendard_extracted"
cp "${WORK_DIR}/pretendard_extracted/public/static/Alternative/"*.ttf "${PRETENDARD_DIR}/"
rm -rf "${WORK_DIR}/Pretendard.zip" "${WORK_DIR}/pretendard_extracted"

D2CODING_DIR="${WORK_DIR}/rootfs/usr/local/share/fonts/D2Coding"
mkdir -p "${D2CODING_DIR}"
curl -L -o "${WORK_DIR}/D2Coding.zip" "https://github.com"
unzip -q "${WORK_DIR}/D2Coding.zip" -d "${WORK_DIR}/d2coding_extracted"
find "${WORK_DIR}/d2coding_extracted" -name "*.ttf" -exec cp {} "${D2CODING_DIR}/" \;
rm -rf "${WORK_DIR}/D2Coding.zip" "${WORK_DIR}/d2coding_extracted"

chroot "${WORK_DIR}/rootfs" fc-cache -f -v

echo "=== [5/6] 시스템 런타임 설정 (MATE-Terminal, Nemo, uutils, Fcitx5 한글 프리셋) ==="
# 1. rc.conf 통합 및 언어/입력기 환경 변수 선언 기본 설정
cat << 'EOF' > "${WORK_DIR}/rootfs/etc/rc.conf"
hostname="alphapress"
zfs_enable="YES"
dtraceall_enable="YES"
dbus_enable="YES"
gdm_enable="YES"
avahi_daemon_enable="YES"
kld_list="i915kms amdgpu"
EOF

# 2. 로케일 환경 변수 및 Fcitx5 한글 입력기 전역 활성화 환경 설정
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

# 3. loader.conf & fstab
cat << 'EOF' > "${WORK_DIR}/rootfs/boot/loader.conf"
dtraceall_load="YES"
autoboot_delay="2"
EOF

cat << 'EOF' > "${WORK_DIR}/rootfs/etc/fstab"
proc                /proc           procfs  rw              0       0
linprocfs           /compat/linux/proc linprocfs rw          0       0
EOF
mkdir -p "${WORK_DIR}/rootfs/compat/linux/proc"

# 4. 라이브 부팅 후 실행 스크립트 (Flatpak 및 Fcitx5 백그라운드 자동 실행)
cat << 'EOF' > "${WORK_DIR}/rootfs/etc/rc.local"
#!/bin/sh
flatpak remote-add --if-not-exists flathub https://flathub.org
flatpak install -y flathub io.github.kolunmi.Bazaar
flatpak install -y flathub io.github.mclab7.MissionCenter
ln -sf /var/lib/flatpak/exports/share/applications/* /usr/local/share/applications/
EOF
chmod +x "${WORK_DIR}/rootfs/etc/rc.local"

# 5. GNOME 환경설정 컴파일 (MATE-Terminal, Nemo 기본 매핑 및 104키 한글 레이아웃 고정)
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
chroot "${WORK_DIR}/rootfs" dconf update

# 6. Rust 기반 uutils를 시스템 표준 coreutils로 완전 치환 및 오버레이
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
pkg -c "${WORK_DIR}/rootfs" clean -y

makefs -t cd9660 -o rockridge -o label="${DISTRO_NAME}" -o bootimage="i386;/boot/cdboot" -o no-emul-boot "${ISO_PATH}" "${WORK_DIR}/rootfs"

echo "=============================================================================="
echo "🎉 Ultimate 데스크탑 배포판 ISO 빌드가 끝났습니다!"
echo "📍 생성된 파일 위치: ${ISO_PATH}"
echo "=============================================================================="
