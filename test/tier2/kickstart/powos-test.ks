# PowOS Tier-2 Test Kickstart — unattended Anaconda install
#
# This is %included AFTER bib's generated kickstart (which handles
# ostreecontainer deployment). It automates disk selection and install
# so Stage D can run without human interaction.
#
# Pass to bib:  --anaconda-ks test/tier2/kickstart/powos-test.ks
# Or inject via floppy image with inst.ks=hd:fd0:/ks.cfg on the cmdline.

# Headless, unattended
text
eula --agreed

# Locale
lang en_US.UTF-8
keyboard us
timezone UTC --utc

# Disk: first virtio disk, wipe and autopart
ignoredisk --only-use=vda
zerombr
clearpart --all --initlabel --drives=vda
autopart --type=plain

# Network
network --bootproto=dhcp --device=link --activate --hostname=powos-test

# Reboot into the installed system
reboot

# Post-install: ensure SSH access for the test harness
%post --log=/var/log/powos-test-ks-post.log
# sshd should already be enabled in the PowOS image, but be explicit
systemctl enable sshd.service 2>/dev/null || true

# Ensure password auth for test SSH access
if [ -f /etc/ssh/sshd_config ]; then
    sed -i 's/^#*PasswordAuthentication.*/PasswordAuthentication yes/' /etc/ssh/sshd_config
fi

# Verify powos user exists (should be baked into the image)
if ! id powos &>/dev/null; then
    useradd -m -G wheel powos
    echo "powos:powos" | chpasswd
fi
%end
