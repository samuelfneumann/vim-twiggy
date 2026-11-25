" Run from the plugin root with Fugitive on 'runtimepath':
" vim -Nu NONE -n -es --cmd 'set rtp^=../vim-fugitive' -S tests/rebase.vim
" Add --cmd 'let g:twiggy_use_vim9 = 0' to test the legacy implementation.
set nocompatible
" Resolve relative runtime entries before changing to the fixture repository.
let &runtimepath = join(map(split(&runtimepath, ','), 'fnamemodify(v:val, ":p")'), ',')
set shell=/bin/bash
execute 'set runtimepath^=' . fnameescape(getcwd())
runtime plugin/fugitive.vim
runtime plugin/twiggy.vim

let s:root = tempname()
call mkdir(s:root, 'p')

function! s:Git(repo, args) abort
  let output = system('git -C ' . shellescape(a:repo) . ' ' . a:args)
  if v:shell_error
    throw output
  endif
  return output
endfunction

try
  let s:repo = s:root . '/repo'
  call mkdir(s:repo)
  call s:Git(s:repo, 'init -b main')
  call s:Git(s:repo, 'config user.name Twiggy')
  call s:Git(s:repo, 'config user.email twiggy@example.test')
  call writefile(['base'], s:repo . '/file')
  call s:Git(s:repo, 'add file')
  call s:Git(s:repo, 'commit -m base')
  call s:Git(s:repo, 'branch topic')
  call writefile(['main'], s:repo . '/file')
  call s:Git(s:repo, 'commit -am main')

  " Exercise both a directory and a linked worktree's .git file.
  for s:linked in [0, 1]
    let s:tree = s:linked ? s:root . '/linked' : s:repo
    if s:linked
      call s:Git(s:repo, 'worktree add -b linked-topic ' . shellescape(s:tree) . ' topic')
    else
      call s:Git(s:repo, 'checkout topic')
    endif
    call writefile(['topic ' . s:linked], s:tree . '/file')
    call s:Git(s:tree, 'commit -am topic')
    execute 'cd ' . fnameescape(s:tree)
    execute 'edit ' . fnameescape(s:tree . '/file')
    call FugitiveDetect()
    Twiggy
    wincmd p
    call system('git -C ' . shellescape(s:tree) . ' rebase main')
    call assert_notequal(0, v:shell_error, 'fixture must stop at a conflict')
    let t:branches_changed = 1
    doautocmd User FugitiveChanged
    call assert_equal('rebase', t:twiggy_git_mode, 'conflicted rebase')
    call assert_equal('rebase in progress', getbufline(t:twiggy_bufnr, 1)[0])

    call writefile(['resolved'], s:tree . '/file')
    Git
    " A .git file is a valid Fugitive repository identifier.
    let b:git_dir = s:tree . '/.git'
    call search('^Unstaged ', 'w')
    call search('file$', 'W')
    " Exercise Fugitive's actual stage mapping and Twiggy's event refresh.
    let t:branches_changed = 1
    normal s
    call assert_equal('', s:Git(s:tree, 'diff --diff-filter=U --name-only'))
    call assert_match('resolved', s:Git(s:tree, 'show :file'))
    call assert_equal('rebase', t:twiggy_git_mode, 'fully staged rebase')
    call assert_equal('rebase in progress', getbufline(t:twiggy_bufnr, 1)[0])

    call s:Git(s:tree, 'rebase --abort')
    let t:branches_changed = 1
    doautocmd User FugitiveChanged
    call assert_equal('normal', t:twiggy_git_mode, 'aborted rebase')
    call win_execute(bufwinid(t:twiggy_bufnr), 'quit')
    only!
  endfor
catch
  call add(v:errors, v:exception . ' at ' . v:throwpoint)
finally
  call delete(s:root, 'rf')
endtry

if !empty(v:errors)
  call writefile(v:errors, '/dev/stderr')
  cquit
endif
qa!
