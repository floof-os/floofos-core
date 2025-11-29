# ~/.bashrc: executed by bash(1) for non-login shells.

# Note: PS1 and umask are already set in /etc/profile. You should not
# need this unless you want different defaults for root.
# PS1='${debian_chroot:+($debian_chroot)}\h:\w\$ '
# umask 022

# You may uncomment the following lines if you want `ls' to be colorized:
# export LS_OPTIONS='--color=auto'
# eval "`dircolors`"
# alias ls='ls $LS_OPTIONS'
# alias ll='ls $LS_OPTIONS -l'
# alias l='ls $LS_OPTIONS -lA'
#
# Some more alias to avoid making mistakes:
# alias rm='rm -i'
# alias cp='cp -i'
# alias mv='mv -i'

export PATH=$PATH:/usr/local/go/bin
export PS1='[\u@\h \W]\$ '
alias ll='ls -lah'
alias write='/etc/vppcfg/.venv/bin/vppcfg dump -o /etc/vpp/dataplane.yaml'
alias check='/etc/vppcfg/.venv/bin/vppcfg check -c /etc/vpp/dataplane.yaml'
alias commit='/etc/vppcfg/.venv/bin/vppcfg plan --novpp -c /etc/vpp/dataplane.yaml -o /etc/vpp/config/vppcfg.vpp'
alias vpp='vppctl'
alias bird='birdc'

# Root: Auto-launch FloofCTL on all logins (SSH and console)
if [[ -t 0 && -z "$FLOOFCTL_SHELL" ]]; then
    export FLOOFCTL_SHELL=1
    /usr/local/bin/cli
    # Note: No exec - allow return to bash after cli exit
fi
