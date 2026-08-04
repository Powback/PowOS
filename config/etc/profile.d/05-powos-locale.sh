# 05-powos-locale.sh — guarantee a UTF-8 locale at the very start of a session.
#
# Why this is 05- (early): Fedora's own lang.sh sorts AFTER the numeric PowOS
# scripts, and sshd here does not AcceptEnv the client's locale. So a fresh SSH
# login starts with LANG unset (C/POSIX). That matters because
# 50-powos-tmux-resume.sh exec()s tmux on login — a tmux client that attaches
# without a UTF-8 locale renders wide/box/glyph characters (Claude Code's UI,
# tmux's own status line) as '?'. Setting UTF-8 here, before 49/50 and before
# any TUI runs, fixes it. Only touches the locale when it is not already UTF-8,
# so an explicit user locale is respected.

case "${LC_ALL:-${LC_CTYPE:-${LANG:-}}}" in
    *[Uu][Tt][Ff]-8* | *[Uu][Tt][Ff]8*) : ;;   # already UTF-8, leave it
    *) export LANG=C.UTF-8 ;;
esac
