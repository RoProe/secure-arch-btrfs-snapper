# ===== INSTANT PROMPT =====
if [[ -r "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh" ]]; then
  source "${XDG_CACHE_HOME:-$HOME/.cache}/p10k-instant-prompt-${(%):-%n}.zsh"
fi

# ===== OH MY ZSH =====
export ZSH="$HOME/.oh-my-zsh"
ZSH_THEME="powerlevel10k/powerlevel10k"
plugins=(git zsh-autosuggestions zsh-syntax-highlighting)
source $ZSH/oh-my-zsh.sh

# ===== EDITOR =====
export EDITOR='nvim'
export VISUAL='nvim'

# ===== FZF =====
source /usr/share/fzf/key-bindings.zsh

# ===== ZOXIDE =====
eval "$(zoxide init zsh)"

# ===== ALIASES =====
alias cd='z'
alias ls='eza --icons'
alias ll='eza -l --icons --git'
alias la='eza -la --icons --git'

# ===== POWERLEVEL10K =====
[[ ! -f ~/.p10k.zsh ]] || source ~/.p10k.zsh
