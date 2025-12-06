# FloofOS Aliases
alias ll='ls -lah'
alias write='/etc/vppcfg/.venv/bin/vppcfg dump -o /etc/vpp/dataplane.yaml'
alias check='/etc/vppcfg/.venv/bin/vppcfg check -c /etc/vpp/dataplane.yaml'
alias commit='/etc/vppcfg/.venv/bin/vppcfg plan --novpp -c /etc/vpp/dataplane.yaml -o /etc/vpp/config/vppcfg.vpp'
