" twiggy.vim -- Maintain your bearings while branching with git
" Maintainer: Samuel Neumann <samuelfneumann@gmail.com>
" Website:    https://samuelfneumann.github.io/
" License:    Same terms as Vim itself (see :help license)

if exists('g:loaded_twiggy') || &cp
  finish
endif
let g:loaded_twiggy = 1

function! UseVim9()
  return get(g:, 'twiggy_use_vim9', has('vim9script'))
endfunction

function! TwiggyComplete(A,L,P) abort
  let parts = split(a:L)
  let subcommands = ['switch', 'close']

  if len(parts) <= 2 && (len(parts) < 2 || index(subcommands, parts[1]) < 0)
    let completions = ''
    for cmd in subcommands
      if match(cmd, '^' . a:A) >= 0
        let completions = completions . cmd . "\n"
      endif
    endfor
    return completions
  elseif len(parts) > 1 && parts[1] ==# 'switch'
    return TwiggyCompleteBranches(a:A, a:L, a:P)
  endif

  return ''
endfunction

function! TwiggyCompleteBranches(A,L,P) abort
  let branches = ''

  if UseVim9()
	  let loop_branches = twiggy#get_branches()
  else
	  let loop_branches = twiggy9#GetBranches()
  endif

  for branch in loop_branches
    let slicepos = len(split(a:A, '/')) - 1
    let branch = join(split(branch.fullname, '/')[0:slicepos], '/')
    let branches = branches . branch . "\n"
  endfor

  return branches
endfunction

command -nargs=* -complete=custom,TwiggyComplete Twiggy if UseVim9() | call twiggy9#Main(<f-args>) | else | call twiggy#Main(<f-args>) | endif
command -nargs=* -complete=custom,TwiggyComplete T call if UseVim9() | call twiggy9#Main(<f-args>) | else | call twiggy#Main(<f-args>) | endif
command CloseTwiggyOutput if UseVim9() | call twiggy9#CloseOutputBuffer() | else | call twiggy#CloseOutputBuffer() | endif
