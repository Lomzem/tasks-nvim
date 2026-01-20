" Syntax file for tasks-nvim
" Conceals the task ID prefix at the start of each line

if exists("b:current_syntax")
  finish
endif

" Match the /ID prefix at the start of lines and conceal it
" The ID can be a Google ID (alphanumeric, base64-like) or new:N
syntax match tasksId /^\/[^ ]* / conceal

let b:current_syntax = "tasks"
