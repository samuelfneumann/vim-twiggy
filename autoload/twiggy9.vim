vim9script

# twiggy.vim -- Maintain your bearings while branching with git
# Maintainer: Samuel Neumann <samuelfneumann@gmail.com>
# Website:    https://samuelfneumann.github.io/
# License:    Same terms as Vim itself (see :help license)

if exists('g:autoloaded_twiggy')
  finish
endif
g:autoloaded_twiggy = 1

highlight default link TwiggyCommitMsg Normal

# -----------------------------------------------------------------------------
# Script state
# -----------------------------------------------------------------------------
var init_line = 0
var mappings = {}
var branch_line_refs = {}
var last_branch_under_cursor = {}
var last_output = []
var requires_buf_refresh = 1
var sorted = 0
var git_cmd_run = 0
var worktree_branches = {}
var total_lines = 0
var branches_not_in_reflog = []

var branch_marker = {
  local: '(l)',
  remote: '(r)',
}
var branch_marker_vmagic = {
  local: '\(l\)',
  remote: '\(r\)',
}

# -----------------------------------------------------------------------------
# Utility
# -----------------------------------------------------------------------------
def Buffocus(bufnr_: any)
  var switchbuf_cached = &switchbuf
  set switchbuf=useopen
  execute 'sb ' .. bufnr_
  execute 'set switchbuf=' .. switchbuf_cached
enddef

def Sub(str_: any, pat: any, rep: any): string
  return substitute(str_, '\v\C' .. pat, rep, '')
enddef

def Gsub(str_: any, pat: any, rep: any): string
  return substitute(str_, '\v\C' .. pat, rep, 'g')
enddef

def Fexists(file: any): bool
  return !empty(glob(file))
enddef

def EncodeMapping(mapping: any): string
  return Sub(mapping, '\v^\<', '___')
enddef

def Mapping(mapping: any, fn: any, args: any)
  mappings[EncodeMapping(mapping)] = [fn, args]
  execute 'nnoremap <buffer> <silent> ' .. mapping
      .. ' <ScriptCmd>CallMapping(''' .. EncodeMapping(mapping) .. ''')<CR>'
enddef

def VisualMapping(mapping: any, fn: any, args: any)
  execute 'xnoremap <buffer> <silent> ' .. mapping
      .. ' <ScriptCmd>VisualCall(''' .. fn .. ''', ' .. string(args) .. ')<CR>'
enddef

def GetVim9Indicator(force: bool=false): string
	const indicator = "(vim9)"
	if force | return indicator | endif
	return get(g:, 'twiggy_show_vim9_indicator', true) ? indicator : ''
enddef

# -----------------------------------------------------------------------------
# Icons
# -----------------------------------------------------------------------------
var icon_set: list<any>
if exists('g:twiggy_icons') && type(g:twiggy_icons) == v:t_list && len(filter(copy(g:twiggy_icons), (_, val) => type(val) == v:t_string && strchars(val) == 1)) == 8
  icon_set = g:twiggy_icons
elseif has('multi_byte')
  icon_set = ['*', '✓', '↑', '↓', '↕', '∅', '✗', '⊞']
else
  icon_set = ['*', '=', '+', '-', '~', '%', 'x', '+']
endif

var ellipsis = has('multi_byte') ? '…' : '...'
var icons = {}
icons.current = icon_set[0]
icons.tracking = icon_set[1]
icons.ahead = icon_set[2]
icons.behind = icon_set[3]
icons.both = icon_set[4]
icons.detached = icon_set[5]
icons.unmerged = icon_set[6]
icons.worktree = icon_set[7]

# -----------------------------------------------------------------------------
# Options
# -----------------------------------------------------------------------------
g:twiggy_num_columns = get(g:, 'twiggy_num_columns', 31)
g:twiggy_num_rows = get(g:, 'twiggy_num_rows', 31)
g:twiggy_adapt_columns = get(g:, 'twiggy_adapt_columns', 0)
g:twiggy_split_direction = get(g:, 'twiggy_split_direction', 'vertical')
g:twiggy_split_position = get(g:, 'twiggy_split_position', '')
g:twiggy_local_branch_sort = get(g:, 'twiggy_local_branch_sort', 'alpha')
g:twiggy_local_branch_sorts = get(g:, 'twiggy_local_branch_sorts', ['alpha', 'date', 'track', 'mru'])
g:twiggy_remote_branch_sort = get(g:, 'twiggy_remote_branch_sort', 'alpha')
g:twiggy_remote_branch_sorts = get(g:, 'twiggy_remote_branch_sorts', ['alpha', 'date'])
g:twiggy_group_locals_by_slash = get(g:, 'twiggy_group_locals_by_slash', 1)
g:twiggy_group_remotes_by_slash = get(g:, 'twiggy_group_remotes_by_slash', 0)
g:twiggy_set_upstream = get(g:, 'twiggy_set_upstream', 1)
g:twiggy_prompted_force_push = get(g:, 'twiggy_prompted_force_push', 1)
g:twiggy_enable_remote_delete = get(g:, 'twiggy_enable_remote_delete', 0)
g:twiggy_use_dispatch = get(g:, 'twiggy_use_dispatch', exists('g:loaded_dispatch') && g:loaded_dispatch ? 1 : 0)
g:twiggy_close_on_fugitive_cmd = get(g:, 'twiggy_close_on_fugitive_cmd', 0)
g:twiggy_enable_quickhelp = get(g:, 'twiggy_enable_quickhelp', 1)
g:twiggy_show_full_ui = get(g:, 'twiggy_show_full_ui', g:twiggy_enable_quickhelp)
g:twiggy_git_log_command = get(g:, 'twiggy_git_log_command', '')
g:twiggy_refresh_buffers = get(g:, 'twiggy_refresh_buffers', 1)
g:twiggy_push_set_upstream = get(g:, 'twiggy_push_set_upstream', 1)

def ShowingFullUi(): bool
  return g:twiggy_enable_quickhelp && g:twiggy_show_full_ui
enddef

# -----------------------------------------------------------------------------
# System / Git command helpers
# -----------------------------------------------------------------------------
def System(cmd: any, bg: any, dispatch_opts: any = {}): list<string>
  var command = cmd

  if bg
    if exists('g:loaded_dispatch') && g:loaded_dispatch && g:twiggy_use_dispatch
      if has_key(dispatch_opts, 'no_dispatch') && dispatch_opts.no_dispatch
        execute ':!' .. command
      elseif has_key(dispatch_opts, 'use_start') && dispatch_opts.use_start
        execute ':Start ' .. command
      else
        execute ':Dispatch ' .. command
      endif
    else
      execute ':!' .. command
    endif
  else
    var output = systemlist(command)
    if v:shell_error != 0
      last_output = output
    endif

    return output
  endif

  return []
enddef

def AttnMode(): bool
  if exists('t:twiggy_git_mode') && index(['rebase', 'merge', 'cherry-pick', 'stash'], t:twiggy_git_mode) >= 0
    return true
  endif
  return false
enddef

def Gitize(cmd: any): string
  var git_cmd: string
  if exists('t:twiggy_bufnr') && t:twiggy_bufnr == bufnr('')
    git_cmd = t:twiggy_git_cmd
  else
    git_cmd = g:FugitiveShellCommand()
  endif
  return git_cmd .. ' ' .. cmd
enddef

def GitCmd(cmd: any, bg: any, dispatch_opts: any = {}): list<string>
  var full_cmd = Gitize(cmd)
  git_cmd_run = 1
  if bg
    System(full_cmd, bg, dispatch_opts)
  else
    return System(full_cmd, bg, dispatch_opts)
  endif

  return []
enddef

def CallMapping(mapping: any)
  var key = EncodeMapping(mapping)
  var deprecated_mappings = {
    F: 'f',
    ___: 'P',
    g___: 'gP',
    ['!___']: '!P',
    V: 'p',
    d___: 'dP',
  }
  var encoded_mapping = EncodeMapping(mapping)
  if has_key(deprecated_mappings, encoded_mapping)
    t:twiggy_deprecation_notice = 'WARNING: `' .. mapping
        .. '` is deprecated and will eventually be removed.  '
        .. 'Use `' .. deprecated_mappings[encoded_mapping] .. '` instead.'
  endif

  if call(mappings[key][0], mappings[key][1])
    ErrorMsg()
  else
    Render()
    RefreshBuffers()
    Buffocus(t:twiggy_bufnr)
    if AttnMode()
      wincmd p
      Git
    endif
    RenderOutputBuffer()
  endif
enddef

def VisualCall(fn: any, args: any)
  var lnum1 = min([line('v'), line('.')])
  var lnum2 = max([line('v'), line('.')])
  execute "normal! \<Esc>"

  var branches = BranchesInRange(lnum1, lnum2)
  if empty(branches)
    return
  endif

  if fn ==# 'YankBranches'
    YankBranches(lnum1, lnum2)
    return
  endif

  var original_line = line('.')
  var failed = false
  for branch in branches
    cursor(branch.line, 1)
    if call(fn, args)
      failed = true
    endif
  endfor
  cursor(original_line, 1)

  if failed
    ErrorMsg()
  else
    Render()
    RefreshBuffers()
    Buffocus(t:twiggy_bufnr)
    RenderOutputBuffer()
  endif
enddef

# -----------------------------------------------------------------------------
# Branch parser
# -----------------------------------------------------------------------------
def ParseBranch(branch_text: any, ref_type: any): dict<any>
  var branch = {}
  var pieces = split(branch_text, "\t\t", true)

  branch.current = pieces[0] ==# '*'
  branch.decoration = ' '

  if branch.current
    var git_mode = exists('t:twiggy_git_mode') ? t:twiggy_git_mode : GetGitMode()
    branch.decoration = git_mode !=# 'normal' ? icons.unmerged : icons.current
  elseif has_key(worktree_branches, pieces[1])
    branch.decoration = icons.worktree
  endif

  var remote_details = pieces[3] .. ' ' .. pieces[4]
  branch.tracking = ''
  if ref_type ==# 'heads'
    branch.tracking = pieces[3]
  endif
  branch.remote = branch.tracking !=# '' ? split(branch.tracking, '/')[0] : ''

  if branch.tracking !=# ''
    if pieces[4] !=# ''
      branch.status = 'both'
      branch.decoration ..= icons.both
    elseif match(remote_details, '\vahead [0-9]') >= 0
      branch.status = 'ahead'
      branch.decoration ..= icons.ahead
    elseif match(remote_details, '\vbehind [0-9]') >= 0
      branch.status = 'behind'
      branch.decoration ..= icons.behind
    else
      branch.status = ''
      branch.decoration ..= icons.tracking
    endif
  else
    branch.status = ''
    branch.decoration ..= ' '
  endif

  branch.fullname = pieces[1]

  if ref_type ==# 'heads'
    branch.is_local = 1
    branch.type = 'local'
    if g:twiggy_group_locals_by_slash && match(branch.fullname, '/') >= 0
      var group = matchstr(branch.fullname, '\v[^/]*')
      branch.group = group
      branch.name = Sub(branch.fullname, group .. '/', '')
      branch.display_name = branch_marker.local .. branch.fullname
    else
      branch.group = 'local'
      branch.name = branch.fullname
      branch.display_name = branch_marker.local .. branch.fullname
    endif
  else
    branch.is_local = 0
    branch.type = 'remote'
    var branch_split = split(branch.fullname, '/')
    branch.name = join(branch_split[1 :], '/')

    if g:twiggy_group_remotes_by_slash && match(branch.name, '/') >= 0
      var group = matchstr(branch.name, '\v[^/]*')
      branch.group = join([branch_split[0], group], '/')
      branch.name = Sub(branch.name, group .. '/', '')
      branch.display_name = branch_marker.remote .. branch.fullname
    else
      branch.group = branch_split[0]
      branch.name = join(branch_split[1 :], '/')
      branch.display_name = branch_marker.remote .. branch.fullname
    endif
  endif

  if !has_key(branch, 'display_name')
    branch.display_name = branch.name
  endif

  remote_details = pieces[3]
  if pieces[4] !=# ''
    remote_details = remote_details .. ': ' .. pieces[4][1 : -2]
  endif

  branch.hash = pieces[2]
  branch.msg = pieces[5]
  branch.remote_branch = pieces[3]
  branch.remote_info = pieces[4][1 : -2]
  branch.remote_details = remote_details

  if empty(branch.name)
    return {}
  endif
  return branch
enddef

# -----------------------------------------------------------------------------
# Git
# -----------------------------------------------------------------------------
def NoCommits(): bool
  return Gsub(GitCmd('rev-list -n 1 --all | wc -l', 0)[0], ' ', '') ==# '0'
enddef

def DirtyTree(): bool
  return !empty(GitCmd('diff --shortstat', 0))
enddef

def GitBranchVv(ref_type: any): list<any>
  var branches = []
  var format = join([
    '%(HEAD)',
    '%(refname:short)',
    '%(objectname:short)',
    '%(upstream:short)',
    '%(upstream:track)',
    '%(contents:subject)',
  ], "\t\t")

  for branch in GitCmd('for-each-ref refs/' .. ref_type .. " --format=$'" .. format .. "'", 0)
    var parsed = ParseBranch(branch, ref_type)
    if !empty(parsed) && !empty(parsed.name)
      add(branches, parsed)
    endif
  endfor

  return branches
enddef

def GetGitMode(): string
  var git_dir = exists('t:twiggy_git_dir') ? t:twiggy_git_dir : b:git_dir
  if isdirectory(git_dir .. '/rebase-apply') || isdirectory(git_dir .. '/rebase-merge')
    return 'rebase'
  elseif Fexists(git_dir .. '/CHERRY_PICK_HEAD')
    return 'cherry-pick'
  elseif Fexists(git_dir .. '/MERGE_HEAD')
    return 'merge'
  elseif !empty(GitCmd('diff --diff-filter=U --name-only', 0))
    return 'stash'
  else
    return 'normal'
  endif
enddef

def UpdateWorktreeBranches()
  worktree_branches = {}
  var worktree_count = 0
  for line_ in GitCmd('worktree list --porcelain', 0)
    if line_ =~# '^worktree '
      worktree_count += 1
    elseif line_ =~# '^branch ' && worktree_count > 1
      var branchname = substitute(matchstr(line_, '^branch \zs.*'), '^refs/heads/', '', '')
      worktree_branches[branchname] = 1
    endif
  endfor
enddef

export def GetBranches(): list<any>
  UpdateWorktreeBranches()
  var locals = GitBranchVv('heads')
  var locals_sorted = []

  var head = GitCmd('rev-parse --symbolic-full-name --abbrev-ref HEAD', 0)[0]
  if head ==# 'HEAD'
    add(locals_sorted, {
      decoration: icons.current .. icons.detached,
      status: 'detached',
      fullname: 'HEAD',
      name: 'HEAD@' .. GitCmd('rev-parse --revs-only --short HEAD', 0)[0],
      is_local: 1,
      current: 1,
      remote: GitCmd('remote', 0)[0],
      type: 'local',
      tracking: '',
      details: 'detached',
      group: 'local',
    })
  endif

  var reflog = GetUniqBranchNamesFromReflog()
  branches_not_in_reflog = []

  var local_refs = {}
  for local in locals
    local_refs[local.fullname] = local
    if index(reflog, local.name) < 0
      add(branches_not_in_reflog, local.name)
    endif
  endfor

  for branch_name in reflog
    if has_key(local_refs, branch_name)
      if g:twiggy_local_branch_sort ==# 'mru'
        add(locals_sorted, local_refs[branch_name])
        remove(locals, index(locals, local_refs[branch_name]))
      endif
    endif
  endfor

  if g:twiggy_local_branch_sort ==# 'track'
    var ahead_branches = []
    var behind_branches = []
    var both_branches = []
    var up_to_date_tracking_branches = []
    var non_tracking_branches = []

    for branch in locals
      if branch.tracking !=# ''
        if branch.status ==# 'ahead'
          add(ahead_branches, branch)
        elseif branch.status ==# 'behind'
          add(behind_branches, branch)
        elseif branch.status ==# 'both'
          add(both_branches, branch)
        else
          add(up_to_date_tracking_branches, branch)
        endif
      else
        add(non_tracking_branches, branch)
      endif
    endfor

    locals = []
    extend(extend(extend(extend(extend(locals_sorted, ahead_branches), both_branches), behind_branches), up_to_date_tracking_branches), non_tracking_branches)
  endif

  if g:twiggy_local_branch_sort ==# 'date'
    for branch_name in GetByCommiterDate('heads')
      if has_key(local_refs, branch_name)
        add(locals_sorted, local_refs[branch_name])
        remove(locals, index(locals, local_refs[branch_name]))
      endif
    endfor
  endif

  locals = extend(locals_sorted, locals)

  var remotes = GitBranchVv('remotes')
  var remotes_sorted = []

  if g:twiggy_remote_branch_sort ==# 'date'
    var remote_refs = {}

    for branch in remotes
      remote_refs[branch.fullname] = branch
    endfor

    for remote in GitCmd('remote', 0)
      for branch_name in GetByCommiterDate('remotes/' .. remote)
        var remote_branch_name = remote .. '/' .. branch_name
        if has_key(remote_refs, remote_branch_name)
          add(remotes_sorted, remote_refs[remote_branch_name])
          remove(remotes, index(remotes, remote_refs[remote_branch_name]))
        endif
      endfor
    endfor
  endif

  return extend(locals, extend(remotes_sorted, remotes))
enddef


def GetCurrentBranch(): string
  return GitCmd('rev-parse --abbrev-ref HEAD', 0)[0]
enddef

def GetCurrentBranchRemoteUpstream(): string
  var remote = GitCmd('rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null', 0)
  if empty(remote)
    return ''
  endif
  return remote[0]
enddef

def GetCurrentBranchRemotePush(): string
  var remote = GitCmd('rev-parse --abbrev-ref --symbolic-full-name @{push} 2>/dev/null', 0)
  if empty(remote)
    return ''
  endif
  return remote[0]
enddef

def BranchExists(branch: any): bool
  GitCmd('show-ref --verify --quiet refs/heads/' .. branch, 0)
  return !v:shell_error
enddef

def BranchUnderCursor(): any
  var line_no = line('.')
  if has_key(branch_line_refs, line_no)
    return branch_line_refs[line_no]
  endif
  return ''
enddef

def g:TwiggyBranchUnderCursor(): any
  if &ft !=# 'twiggy'
    throw 'Not in twiggy buffer'
  endif
  return BranchUnderCursor()
enddef

def BranchesInRange(lnum1: any, lnum2: any): list<any>
  var branches = []
  for line_no in range(lnum1, lnum2)
    if has_key(branch_line_refs, line_no)
      add(branches, branch_line_refs[line_no])
    endif
  endfor
  return branches
enddef

def GetUniqBranchNamesFromReflog(): list<any>
  var cmd = "awk 'FNR==NR { a[$NF]; next } $NF in a' <(" .. Gitize('branch --list') .. ') '
  cmd ..= '<(' .. Gitize('reflog') .. " | awk -F\" \" '/checkout: moving from/ { print $8 }' | "
  cmd ..= 'awk ' .. shellescape('!f[$0]++') .. ')'
  return System(cmd, 0, 0)
enddef

def GetMergedBranches(): list<any>
  # Preserves the original function's behavior, although this does not appear
  # to be used elsewhere in the file.
  return map(GitCmd('branch --list --merged', 0), (_, _) => "\n")
enddef

def GetByCommiterDate(ref_type: any): list<any>
  var cmd = Gitize(
    "for-each-ref --sort=-committerdate --format='%(refname)' "
      .. 'refs/' .. ref_type .. " | sed 's/refs\\/"
      .. Sub(ref_type, '/', '\\/') .. "\\///g'"
  )
  return System(cmd, 0, 0)
enddef

def UpdateLastBranchUnderCursor()
  try
    last_branch_under_cursor = BranchUnderCursor()
  catch
    return
  endtry
enddef

# -----------------------------------------------------------------------------
# UI views
# -----------------------------------------------------------------------------
def StandardView(): list<any>
  var groups = {}
  groups.local = {}
  groups.remote = {}
  var group_refs = {}
  group_refs.local = []
  group_refs.remote = []
  init_line = 0
  branch_line_refs = {}

  var branches = GetBranches()
  for branch in branches
    if empty(branch.name)
      continue
    endif

    if !has_key(groups[branch.type], branch.group)
      groups[branch.type][branch.group] = {}
      var group_name: string
      if branch.group ==# 'local'
        group_name = t:twiggy_git_mode ==# 'normal' ? 'local' : t:twiggy_git_mode
      elseif branch.type ==# 'remote'
        group_name = 'r:' .. branch.group
      else
        group_name = branch.group
      endif
      groups[branch.type][branch.group].name = group_name
      groups[branch.type][branch.group].branches = []
      if branch.group ==# 'local'
        group_refs.local = extend([groups.local.local], group_refs.local)
      else
        add(group_refs[branch.type], groups[branch.type][branch.group])
      endif
    endif

    add(groups[branch.type][branch.group].branches, branch)
  endfor

  var output = []
  var line_no = ShowingFullUi() ? 1 : 0

  for group_type in ['local', 'remote']
    for group_ref in group_refs[group_type]
      line_no += 1
      if line_no != 1
        add(output, '')
        line_no += 1
      endif

      var sort_name = get(g:, 'twiggy_' .. group_type .. '_branch_sort')
      add(output, group_ref.name .. ' [' .. sort_name .. ']')

      for branch in group_ref.branches
        add(output, branch.decoration .. get(branch, 'display_name', branch.name))
        line_no += 1
        branch.line = line_no
        branch_line_refs[line_no] = branch
        if !init_line
          if sorted
            if branch.fullname ==# last_branch_under_cursor.fullname
              sorted = 0
              init_line = branch.line
            endif
          elseif !git_cmd_run && !empty(last_branch_under_cursor)
            init_line = last_branch_under_cursor.line
            git_cmd_run = 0
          else
            if match(branch.fullname, '(no branch') >= 0
              init_line = line_no
            elseif branch.status ==# 'detached'
              init_line = line_no
            elseif !empty(last_branch_under_cursor)
              init_line = last_branch_under_cursor.line
            elseif branch.current
              init_line = branch.line
            endif
          endif
        endif
      endfor
    endfor
  endfor

  return output
enddef

def QuickhelpView(): list<any>
  var output = []
  add(output, 'Twiggy Quickhelp')
  add(output, '===========================')
  add(output, '<space>R  Refresh')
  add(output, '<C-N>     jump to next group')
  add(output, '<C-P>     jump to prev group')
  add(output, 'JL        jump to curr branch')
  add(output, 'JU        jump to curr upstream')
  add(output, 'JP        jump to curr push')
  add(output, 'g?        toggle this help')
  add(output, '---------------------------')
  add(output, 'w/ the cursor on a branch:')
  add(output, '---------------------------')
  add(output, '<CR>      checkout')
  add(output, 'c         checkout')
  add(output, 'o         checkout')
  add(output, 'cm        checkout --merge')
  add(output, 'om        checkout --merge')
  add(output, 'C         checkout remote')
  add(output, 'O         checkout remote')
  add(output, 'Cm        checkout remote --merge')
  add(output, 'Om        checkout remote --merge')
  add(output, 'gc        checkout as: <name>')
  add(output, 'go        checkout as: <name>')
  add(output, 'f         fetch remote')
  add(output, 'm         merge')
  add(output, 'M         merge remote')
  add(output, 'gm        `m` --no-ff')
  add(output, 'gM        `M` --no-ff')
  add(output, 'r         rebase')
  add(output, 'R         rebase remote')
  add(output, 'gri       `r` -i --autostash')
  add(output, 'gRi       `R` -i --autostash')
  add(output, 'P         push')
  add(output, 'gP        push (prompted)')
  add(output, '!P        push --force-with-lease')
  add(output, 'p         pull')
  if g:twiggy_git_log_command !=# ''
    add(output, 'gl          git log')
    add(output, 'gL          git log `..`')
  endif
  add(output, ',         rename')
  add(output, 'yy        yank <branch>')
  add(output, 'dd        delete')
  if g:twiggy_enable_remote_delete
    add(output, 'dP          delete from server')
  endif
  add(output, '.         :Git <cursor> <branch>')
  add(output, '<<        stash')
  add(output, '>>        pop stash')
  add(output, '----------------------------')
  add(output, 'sorting, etc:')
  add(output, '----------------------------')
  add(output, 'i         cycle sorts')
  add(output, 'I         `i` in reverse')
  add(output, 'gi        cycle remote sorts')
  add(output, 'gI        `gi` in reverse')
  add(output, 'a         toggle slash-grouping')
  add(output, 'ga        toggle slash-grouping remotes')
  if g:twiggy_show_full_ui
    add(output, '')
    add(output, '****************************')
    add(output, 'For more detailed info:')
    add(output, ':help twiggy-mappings')
  endif
  return output
enddef

def RebaseView(): list<string>
  return ['rebase in progress', '', 'from this window:', '  c to continue', '  s to skip', '  a to abort']
enddef

def MergeView(): list<string>
  return ['merge in progress', '', 'from this window:', '  c to continue', '  a to abort']
enddef

def CherryPickView(): list<string>
  return ['cherry pick in progress', '', 'from this window:', '  c to continue', '  a to abort']
enddef

def StashView(): list<string>
  return ['stash conflicts', '', 'from this window:', '  c to continue (commit)', '  a to abort (reset)']
enddef

def ShowBranchDetails()
  var line_no = line('.')
  if !has_key(branch_line_refs, line_no)
    return
  endif

  var branch_ref = branch_line_refs[line_no]
  var max_len = &columns - 16
  var decor = branch_ref.decoration
  var name = branch_ref.name
  var hash = get(branch_ref, 'hash', '')
  var msg = get(branch_ref, 'msg', '')
  var remote_branch = get(branch_ref, 'remote_branch', '')
  var remote_info = get(branch_ref, 'remote_info', '')
  var status = get(branch_ref, 'status', '')
  var total_len = 8 + strcharlen(decor) + len(msg) + len(name) + len(hash) + len(remote_branch) + len(remote_info)

  if total_len > max_len
    msg = msg[0 : max_len + len(msg) - total_len - 1 - strcharlen(ellipsis)] .. ellipsis
  endif
  redraw

  if exists('t:twiggy_deprecation_notice')
    redraw
    echohl WarningMsg
    echomsg t:twiggy_deprecation_notice
    echohl None
    unlet t:twiggy_deprecation_notice
    return
  endif

  for icon in split(decor, '\zs')
    if icon ==# icons.current
      echohl TwiggyCurrent
    elseif icon ==# icons.tracking
      echohl TwiggyTracking
    elseif icon ==# icons.ahead
      echohl TwiggyAhead
    elseif icon ==# icons.behind
      echohl TwiggyBehind
    elseif icon ==# icons.both
      echohl TwiggyAheadBehind
    elseif icon ==# icons.detached
      echohl TwiggyDetached
    elseif icon ==# icons.unmerged
      echohl TwiggyUnmerged
    elseif icon ==# icons.worktree
      echohl TwiggyWorktree
    else
      echohl ErrorMsg
    endif
    echon icon
  endfor
  echohl clear

  if name =~# '\v^HEAD\@[0-9a-fA-F]+'
    echohl TwiggyDetachedText
  else
    echohl TwiggyBranchCurrentName
  endif
  echon name
  echohl clear

  if !empty(hash)
    echon ' ('
    echohl TwiggyCommitHash
    echon hash
    echohl clear
    echon ')'
  endif

  if !empty(remote_branch)
    echon ' ['
    echohl TwiggyUpstream
    echon remote_branch
    echohl clear
    if !empty(remote_info)
      echon ': '
      if status ==# 'ahead'
        echohl TwiggyAhead
      elseif status ==# 'behind'
        echohl TwiggyBehind
      elseif status ==# 'both'
        echohl TwiggyAheadBehind
      endif
      echon remote_info
      echohl clear
    endif
    echon ']'
  endif

  if !empty(msg)
    echohl TwiggyCommitMessage
    echon ' ' .. msg
    echohl clear
    echon
  endif
enddef

def RenderOutputBuffer()
  if empty(last_output)
    return
  endif

  silent keepalt botright new TwiggyOutput
  setlocal filetype=twiggyoutput
  var output = last_output
  var height = len(output)
  if height < 5
    height = 5
  endif
  execute 'resize ' .. height
  normal! ggdG
  setlocal modifiable
  append(0, output)
  normal! ddgg

  setlocal nomodified nomodifiable noswapfile nowrap nonumber
  setlocal buftype=nofile bufhidden=delete
  if exists('+relativenumber')
    setlocal norelativenumber
  endif
  last_output = []

  syntax clear
  syntax match TwiggyOutputText "\v^[^ ](.*)"
  highlight link TwiggyOutputText Comment
  syntax match TwiggyOutputFile "\v^\t(.*)"
  highlight link TwiggyOutputFile File
enddef

export def CloseOutputBuffer()
  for info in getbufinfo()
    if getbufvar(info.bufnr, '&filetype') ==# 'twiggyoutput'
      execute 'bwipeout' info.bufnr
    endif
  endfor
enddef

def Confirm(prompt: any, cmd: any, can_abort: any): number
  redraw
  echohl WarningMsg
  echo prompt .. ' [Yn' .. (can_abort ? 'a' : '') .. ']'
  echohl None

  var input_char = nr2char(getchar())
  if index(['a', "\<esc>"], input_char) >= 0 && can_abort
    return -1
  elseif index(['Y', 'y', "\<cr>"], input_char) >= 0
    execute 'return ' .. cmd
  else
    return -1
  endif

  return 0
enddef

def PromptToStash(): any
  return Confirm('Working tree is dirty.  Stash first?', "GitCmd('stash', 0)", 1)
enddef

def ErrorMsg()
  if v:warningmsg !=# ''
    redraw
    echohl WarningMsg
    echomsg v:warningmsg
    v:warningmsg = ''
    echohl None
  endif
enddef

# -----------------------------------------------------------------------------
# Navigation
# -----------------------------------------------------------------------------
def TraverseBranches(motion: any, count: any = 1)
  for _ in range(count)
    execute 'normal! ' .. motion
    var current_line = line('.')

    var border_line = ShowingFullUi() ? 3 : 1
    if current_line == total_lines && motion ==# 'j'
      return
    elseif motion ==# 'k' && current_line <= border_line
      normal! j
    else
      while getline('.') =~# '\v^[A-Za-z]' || getline('.') ==# ''
        execute 'normal! ' .. motion
      endwhile
    endif
  endfor
enddef

def TraverseGroups(motion: any, end_: any = 0, count: any = 1)
  for _ in range(count)
    if motion ==# 'j'
      if end_
        TraverseBranches('j')
        if search('\v(^[A-Za-z])', 'W')
          TraverseBranches('k')
        else
          normal! G
        endif
      else
        if search('\v^[A-Za-z]', 'W')
          normal! j
        endif
      endif
    elseif motion ==# 'k'
      if end_
        if search('\v^[A-Za-z]', 'bW')
          TraverseBranches('k')
        endif
      else
        TraverseBranches('k')
        if search('\v^[A-Za-z]', 'bW')
          TraverseBranches('j')
        endif
      endif
    endif
  endfor
enddef

def JumpToCurrentBranch()
  search(icons.current)
enddef

def JumpToCurrentUpstream()
  var upstream = GetCurrentBranchRemoteUpstream()
  search(upstream)
enddef

def JumpToCurrentPush()
  var push = GetCurrentBranchRemotePush()
  search(push)
enddef

def Bufrefresh()
  if &ft ==# 'gitcommit'
    Git
  elseif &modifiable && &buftype ==# ''
    try
      silent edit
    catch
    endtry
  endif
enddef

def RefreshBuffers()
  if g:twiggy_refresh_buffers
    if requires_buf_refresh
      windo call Bufrefresh()
    endif
    requires_buf_refresh = 1
  endif
enddef

# -----------------------------------------------------------------------------
# Syntax helpers moved out of Render() because Vim9 def functions cannot safely
# define nested functions in the same legacy style.
# -----------------------------------------------------------------------------
def RenderRemote(conceal_remote: any, remote: any, remote_type: any)
  if conceal_remote && !empty(remote)
    var parts = split(remote, '/')
    var prefix: string
    var name: string
    if len(parts) < 3
      prefix = parts[0] .. '/'
      name = join(parts[1 :], '/')
    else
      prefix = join(parts[0 : 1], '/') .. '/'
      name = join(parts[2 :], '/')
    endif

    execute 'syntax match TwiggyBranchCurrent' .. remote_type .. ' /\v' .. branch_marker_vmagic.remote .. escape(remote, '\/\') .. '$/ contains=TwiggyBranchCurrent' .. remote_type .. 'Prefix,TwiggyBranchCurrent' .. remote_type .. 'Name'
    execute 'syntax match TwiggyBranchCurrent' .. remote_type .. 'Prefix /\V' .. escape(branch_marker.remote .. prefix, '\/') .. '/ contained conceal contains=TwiggyBranchPrefix nextgroup=TwiggyBranchCurrent' .. remote_type .. 'Name'
    execute 'syntax match TwiggyBranchCurrent' .. remote_type .. 'Name /\V' .. escape(name, '\/\') .. '/ contained'
  elseif !conceal_remote && !empty(remote)
    var parts = split(remote, '/')
    var prefix = parts[0] .. '/'
    var name = join(parts[1 :], '/')

    execute 'syntax match TwiggyBranchCurrent' .. remote_type .. ' /\v' .. branch_marker_vmagic.remote .. escape(remote, '\/\') .. '$/ contains=TwiggyBranchCurrent' .. remote_type .. 'Prefix,TwiggyBranchCurrent' .. remote_type .. 'Name'
    execute 'syntax match TwiggyBranchCurrent' .. remote_type .. 'Prefix /\V' .. escape(branch_marker.remote .. prefix, '\/') .. '/ contained conceal contains=TwiggyBranchPrefix nextgroup=TwiggyBranchCurrent' .. remote_type .. 'Name'
    execute 'syntax match TwiggyBranchCurrent' .. remote_type .. 'Name /\V' .. escape(name, '\/\') .. '/ contained'
  endif
enddef

def RenderBranches(current: any, upstream: any, push: any, conceal_local: any, conceal_remote: any)
  syntax clear TwiggyBranch
  syntax clear TwiggyRemoteBranch
  syntax clear TwiggyBranchPrefix
  syntax clear TwiggyBranchCurrent
  syntax clear TwiggyBranchCurrentPrefix
  syntax clear TwiggyBranchCurrentName

  execute 'syntax region TwiggyBranch start=/\v' .. branch_marker_vmagic.local .. '/ end=/\v\S+/ contains=TwiggyBranchBranchPrefix,TwiggyBranchBranchName oneline'
  execute 'syntax region TwiggyRemoteBranch start=/\v' .. branch_marker_vmagic.remote .. '/ end=/\v\S+/ contains=TwiggyBranchRemoteBranchPrefix,TwiggyBranchRemoteBranchName oneline'

  execute 'syntax match TwiggyBranchBranchPrefix /\v' .. branch_marker_vmagic.local .. '/ contained conceal nextgroup=TwiggyBranchBranchName contains=TwiggyBranchPrefix'
  if conceal_local
    execute 'syntax match TwiggyBranchBranchPrefix /\v' .. branch_marker_vmagic.local .. '[-_[:alnum:].]+\// contained conceal nextgroup=TwiggyBranchBranchName contains=TwiggyBranchPrefix'
  endif
  syntax match TwiggyBranchBranchName /\v[-_[:alnum:].\/]+/ contained

  execute 'syntax match TwiggyBranchRemoteBranchPrefix /\v' .. branch_marker_vmagic.remote .. '/ contained conceal nextgroup=TwiggyBranchRemoteBranchName contains=TwiggyBranchPrefix'
  if conceal_remote
    execute 'syntax match TwiggyBranchRemoteBranchPrefix /\v' .. branch_marker_vmagic.remote .. '([-_[:alnum:].]+\/){1,2}/ contained conceal nextgroup=TwiggyBranchRemoteBranchName contains=TwiggyBranchPrefix'
  else
    execute 'syntax match TwiggyBranchRemoteBranchPrefix /\v' .. branch_marker_vmagic.remote .. '([-_[:alnum:].]+\/)/ contained conceal nextgroup=TwiggyBranchRemoteBranchName contains=TwiggyBranchPrefix'
  endif
  syntax match TwiggyBranchRemoteBranchName /\v[-_[:alnum:].\/]+/ contained

  if conceal_local && !empty(current)
    var parts = split(current, '/')
    if len(parts) < 2
      execute 'syntax match TwiggyBranchCurrent ''\v' .. branch_marker_vmagic.local .. current .. '$'' contains=TwiggyBranchCurrentPrefix,TwiggyBranchCurrentName'
      execute 'syntax match TwiggyBranchCurrentPrefix /\V' .. escape(branch_marker.local, '\/') .. '/ contained conceal contains=TwiggyBranchPrefix nextgroup=TwiggyBranchCurrentName'
      execute 'syntax match TwiggyBranchCurrentName /\V' .. current .. '/ contained'
    else
      var prefix = parts[0] .. '/'
      var name = join(parts[1 :], '/')
      execute 'syntax match TwiggyBranchCurrent /\v' .. branch_marker_vmagic.local .. escape(current, '\/\') .. '$/ contains=TwiggyBranchCurrentPrefix,TwiggyBranchCurrentName'
      execute 'syntax match TwiggyBranchCurrentPrefix /\V' .. escape(branch_marker.local .. prefix, '\/') .. '/ contained conceal contains=TwiggyBranchPrefix nextgroup=TwiggyBranchCurrentName'
      execute 'syntax match TwiggyBranchCurrentName /\V' .. escape(name, '\/\') .. '/ contained'
    endif
  elseif !conceal_local && !empty(current)
    execute 'syntax match TwiggyBranchCurrent /\v' .. branch_marker_vmagic.local .. escape(current, '\/\') .. '$/ contains=TwiggyBranchCurrentPrefix,TwiggyBranchCurrentName'
    execute 'syntax match TwiggyBranchCurrentPrefix /\V' .. escape(branch_marker.local, '\/') .. '/ contained conceal contains=TwiggyBranchPrefix nextgroup=TwiggyBranchCurrentName'
    execute 'syntax match TwiggyBranchCurrentName /\V' .. escape(current, '\/\') .. '/ contained'
  endif

  if upstream ==# push
    RenderRemote(conceal_remote, upstream, 'UpstreamPush')
  else
    RenderRemote(conceal_remote, upstream, 'Upstream')
    RenderRemote(conceal_remote, push, 'Push')
  endif

  execute 'syntax match TwiggyBranchPrefix /\v' .. branch_marker_vmagic.local .. '/ contained conceal'
  execute 'syntax match TwiggyBranchPrefix /\v' .. branch_marker_vmagic.remote .. '/ contained conceal'
enddef

def Dot(): string
  var branch = BranchUnderCursor()
  return ':Git  ' .. branch.fullname .. "\<C-Left>\<Left>"
enddef

# -----------------------------------------------------------------------------
# Main renderer
# -----------------------------------------------------------------------------
def Render()
  redraw

  if exists('b:git_dir') && &filetype !=# 'twiggy'
    t:twiggy_git_dir = b:git_dir
    t:twiggy_git_cmd = g:FugitiveShellCommand()
  elseif !exists('t:twiggy_git_cmd')
    echo 'Not a git repository'
    return
  endif

  if !exists('t:twiggy_bufnr') || !(exists('t:twiggy_bufnr') && t:twiggy_bufnr == bufnr(''))
    var fname = 'twiggy://' .. t:twiggy_git_dir .. '/branches'
    if &filetype ==# 'twiggyqh'
      execute 'edit ' .. fname
    else
      if g:twiggy_split_direction ==# 'horizontal'
        execute('silent keepalt ' .. g:twiggy_split_position .. ' :' .. g:twiggy_num_rows .. 'split ' .. fname)
      else
        execute('silent keepalt ' .. g:twiggy_split_position .. ' :' .. g:twiggy_num_columns .. 'vsplit ' .. fname)
      endif
    endif
    setlocal filetype=twiggy buftype=nofile bufhidden=delete
    setlocal nonumber nowrap lisp
    if exists('+relativenumber')
      setlocal norelativenumber
    endif
    t:twiggy_bufnr = bufnr('')
  endif

  if g:twiggy_enable_quickhelp > 0
    nnoremap <buffer> <silent> g? :<C-U>call Quickhelp()<CR>
  endif

  autocmd! BufWinLeave twiggy://*
      \ if exists('t:twiggy_bufnr') |
      \   unlet! t:twiggy_bufnr |
      \   unlet! t:twiggy_git_dir |
      \   unlet! t:twiggy_git_cmd |
      \   unlet! t:twiggy_git_mode |
      \ endif

  if NoCommits()
    set modifiable
    execute('silent 1,$delete _')
    append(0, 'No commits')
    delete _
    set nomodifiable
    return
  endif

  t:twiggy_git_mode = GetGitMode()

  var output = []

  if ShowingFullUi() && !AttnMode()
	const suffix = GetVim9Indicator()
	extend(output, [$"Twiggy\tHelp: g?{empty(suffix) ? '' : "\t"}{suffix}"])
  endif

  if AttnMode()
    var view = {
      rebase: 'RebaseView',
      merge: 'MergeView',
      ['cherry-pick']: 'CherryPickView',
      stash: 'StashView',
    }[t:twiggy_git_mode]
    extend(output, call(view, []))
  else
    extend(output, StandardView())
  endif

  if g:twiggy_adapt_columns && g:twiggy_split_direction !=# 'horizontal'
    var cols = 0
    for line_ in output
      var line_length = len(line_)
      if line_length > cols
        cols = line_length
      endif
    endfor
    execute 'vertical resize ' .. (cols + 3)
  endif

  set modifiable
  execute('silent :1,$delete _')
  append(0, output)
  normal! G
  delete _
  normal! gg

  setlocal nomodified nomodifiable noswapfile winfixwidth

  if AttnMode()
    if t:twiggy_git_mode ==# 'rebase'
      Mapping('c', 'Continue', ['rebase'])
      Mapping('s', 'Skip', [])
      Mapping('a', 'Abort', ['rebase'])
    elseif t:twiggy_git_mode ==# 'merge'
      Mapping('a', 'Abort', ['merge'])
      Mapping('c', 'Continue', ['merge'])
    elseif t:twiggy_git_mode ==# 'cherry-pick'
      Mapping('c', 'Continue', ['cherry-pick'])
      Mapping('a', 'Abort', ['cherry-pick'])
    elseif t:twiggy_git_mode ==# 'stash'
      Mapping('c', 'Continue', ['stash'])
      Mapping('a', 'Abort', ['stash'])
    endif

    syntax match TwiggyAttnModeMapping "\v%3c(s|c|a)"
    highlight link TwiggyAttnModeMapping Identifier
    syntax match TwiggyAttnModeTitle "\v^(rebase|merge|cherry pick) in progress"
    syntax match TwiggyAttnModeTitle "\v^stash conflicts"
    highlight link TwiggyAttnModeTitle Type
    syntax match TwiggyAttnModeInstruction "\v^from this window:"
    highlight link TwiggyAttnModeInstruction String
    normal! 0
    return
  endif

  highlight default link TwiggyCommitHash fugitiveHash
  highlight default link TwiggyUpstreamPush Directory
  highlight default link TwiggyPush Error
  highlight default link TwiggyUpstream fugitiveSymbolicRef
  ShowBranchDetails()
  total_lines = len(output)

  execute 'normal! ' .. init_line .. 'gg'
  normal! 0

  augroup twiggy
    autocmd!
    autocmd CursorMoved twiggy://* call ShowBranchDetails()
    autocmd CursorMoved twiggy://* call UpdateLastBranchUnderCursor()
    autocmd CmdlineLeave * if histget(':', -1) =~ '\v^G(it)?\s+(fetch|pull|push|switch|checkout|branch)' | call Refresh() |  t:branches_changed = 1 | endif
    autocmd User FugitiveChanged if exists('t:branches_changed') && t:branches_changed |  t:branches_changed = 0 | call Refresh() | endif
    autocmd User WorktreeCheckout call Refresh()
  augroup END

  nnoremap <buffer> <silent> cf<space> :<C-U>G fetch<space>
  nnoremap <buffer> <silent> cm<space> :<C-U>G merge<space>
  nnoremap <buffer> <silent> cb<space> :<C-U>G branch<space>
  nnoremap <buffer> <silent> co<space> :<C-U>G checkout<space>
  nnoremap <buffer> <silent> cz<space> :<C-U>G stash<space>
  nnoremap <buffer> <silent> cs<space> :<C-U>G switch<space>
  nnoremap <buffer> <silent> cr<space> :<C-U>G rebase<space>

  nnoremap <buffer> <silent> )      <ScriptCmd>TraverseBranches('j', v:count1)<CR>
  nnoremap <buffer> <silent> (      <ScriptCmd>TraverseBranches('k', v:count1)<CR>
  nnoremap <buffer> <silent> j      <ScriptCmd>TraverseBranches('j', v:count1)<CR>
  nnoremap <buffer> <silent> k      <ScriptCmd>TraverseBranches('k', v:count1)<CR>
  nnoremap <buffer> <silent> <Down> <ScriptCmd>TraverseBranches('j', v:count1)<CR>
  nnoremap <buffer> <silent> <Up>   <ScriptCmd>TraverseBranches('k', v:count1)<CR>
  nnoremap <buffer> <silent> ][     <ScriptCmd>TraverseGroups('j', 1, v:count1)<CR>
  nnoremap <buffer> <silent> []     <ScriptCmd>TraverseGroups('k', 1, v:count1)<CR>
  nnoremap <buffer> <silent> ]]     <ScriptCmd>TraverseGroups('j', 0, v:count1)<CR>
  nnoremap <buffer> <silent> [[     <ScriptCmd>TraverseGroups('k', 0, v:count1)<CR>
  nnoremap <buffer> <silent> <C-N>  <ScriptCmd>TraverseGroups('j', 0, v:count1)<CR>
  nnoremap <buffer> <silent> <C-P>  <ScriptCmd>TraverseGroups('k', 0, v:count1)<CR>
  nnoremap <buffer> <silent> JL     <ScriptCmd>JumpToCurrentBranch()<CR>
  nnoremap <buffer> <silent> JU     <ScriptCmd>JumpToCurrentUpstream()<CR>
  nnoremap <buffer> <silent> JP     <ScriptCmd>JumpToCurrentPush()<CR>
  if ShowingFullUi()
    nnoremap <buffer> <silent> gg    :normal! 4gg<CR>
  else
    nnoremap <buffer> <silent> gg    :normal! 2gg<CR>
  endif

  Mapping('<CR>', 'Checkout', [1, 0])
  Mapping('c', 'Checkout', [1, 0])
  Mapping('C', 'Checkout', [0, 0])
  Mapping('o', 'Checkout', [1, 0])
  Mapping('O', 'Checkout', [0, 0])
  Mapping('cm', 'Checkout', [1, 1])
  Mapping('Cm', 'Checkout', [0, 1])
  Mapping('om', 'Checkout', [1, 1])
  Mapping('Om', 'Checkout', [0, 1])
  Mapping('gc', 'CheckoutAs', [])
  Mapping('go', 'CheckoutAs', [])
  Mapping('dd', 'Delete', [])
  Mapping('yy', 'Yank', [])
  Mapping('F', 'Fetch', [0])
  Mapping('f', 'Fetch', [0])
  Mapping('m', 'Merge', [0, ''])
  Mapping('M', 'Merge', [1, ''])
  Mapping('gm', 'Merge', [0, '--no-ff'])
  Mapping('gM', 'Merge', [1, '--no-ff'])
  Mapping('<space>R', 'Refresh', [])
  Mapping('r', 'Rebase', [0, 0, 0])
  Mapping('R', 'Rebase', [1, 0, 0])
  Mapping('ri', 'Rebase', [0, 0, 1])
  Mapping('Ri', 'Rebase', [1, 0, 1])
  Mapping('gr', 'Rebase', [0, 1, 0])
  Mapping('gR', 'Rebase', [1, 1, 0])
  Mapping('gri', 'Rebase', [0, 1, 1])
  Mapping('gRi', 'Rebase', [1, 1, 1])
  Mapping('^', 'Push', [0, 0, 1])
  Mapping('g^', 'Push', [1, 0, 1])
  Mapping('!^', 'Push', [0, 1, 1])
  Mapping('V', 'Pull', [])
  Mapping('P', 'Push', [0, 0, g:twiggy_push_set_upstream])
  Mapping('gP', 'Push', [1, 0, g:twiggy_push_set_upstream])
  Mapping('!P', 'Push', [0, 1, g:twiggy_push_set_upstream])
  Mapping('p', 'Pull', [])
  Mapping(',', 'Rename', [])
  Mapping('<<', 'Stash', [0])
  Mapping('>>', 'Stash', [1])
  Mapping('i', 'CycleSort', [0, 1])
  Mapping('I', 'CycleSort', [0, -1])
  Mapping('gi', 'CycleSort', [1, 1])
  Mapping('gI', 'CycleSort', [1, -1])
  Mapping('a', 'ToggleSlashSort', [1])
  Mapping('ga', 'ToggleSlashSort', [0])

  VisualMapping('d', 'Delete', [])
  VisualMapping('f', 'Fetch', [0])
  VisualMapping('y', 'YankBranches', [])
  VisualMapping('P', 'Push', [0, 0, g:twiggy_push_set_upstream])
  VisualMapping('!P', 'Push', [0, 1, g:twiggy_push_set_upstream])

  if get(g:, 'twiggy_enable_remote_delete', false)
	  call Mapping('dP',       'DeleteRemote',           [])
	  call VisualMapping('dP', 'DeleteRemote',           [])
  endif

  nnoremap <buffer> <expr> . <ScriptCmd>Dot()

  if g:twiggy_git_log_command ==# ''
    if exists(':GV')
      g:twiggy_git_log_command = 'GV'
    elseif exists(':Gitv')
      g:twiggy_git_log_command = 'Gitv'
    endif
  endif

  if g:twiggy_git_log_command !=# ''
    nnoremap <buffer> gl :exec ':' . g:twiggy_git_log_command . ' ' . <ScriptCmd>BranchUnderCursor().fullname<CR>
    nnoremap <buffer> gL :exec ':' . g:twiggy_git_log_command . ' ' . <ScriptCmd>BranchUnderCursor().fullname . '..'<CR>
  endif

  syntax clear

  execute "syntax match TwiggyGroup '\\v(^[^\\ " .. icons.current .. "]+)'"
  highlight default link TwiggyGroup Type

  highlight default link TwiggyBranch Comment
  highlight default link TwiggyRemoteBranch Comment
  highlight default link TwiggyBranchPrefix Comment
  highlight default link TwiggyBranchBranchPrefix Comment
  highlight default link TwiggyBranchCurrentPrefix Comment
  highlight default link TwiggyBranchCurrentName TwiggyCurrent
  highlight default link TwiggyBranchCurrentUpstreamName TwiggyUpstream
  highlight default link TwiggyBranchCurrentPushName TwiggyPush
  highlight default link TwiggyBranchCurrentUpstreamPushName TwiggyUpstreamPush
  highlight default link TwiggyBranchCurrent Identifier

  &l:conceallevel = 2
  &l:concealcursor = 'nvic'

  var current_branch = GetCurrentBranch()
  var upstream = GetCurrentBranchRemoteUpstream()
  var push = GetCurrentBranchRemotePush()
  RenderBranches(current_branch, upstream, push, g:twiggy_group_locals_by_slash, g:twiggy_group_remotes_by_slash)

  execute "syntax match TwiggyCurrent '\\V\\%1c" .. icons.current .. "'"
  highlight default link TwiggyCurrent Identifier

  execute "syntax match TwiggyTracking '\\V\\%2v" .. icons.tracking .. "'"
  highlight default link TwiggyTracking String

  execute "syntax match TwiggyAhead '\\V\\%2v" .. icons.ahead .. "'"
  highlight default link TwiggyAhead Type

  execute "syntax match TwiggyBehind '\\V\\%2v" .. icons.behind .. "'"
  highlight default link TwiggyBehind Type

  execute "syntax match TwiggyAheadBehind '\\V\\%2v" .. icons.both .. "'"
  highlight default link TwiggyAheadBehind Type

  execute "syntax match TwiggyDetached '\\V\\%2v" .. icons.detached .. "'"
  highlight default link TwiggyDetached ErrorMsg

  execute "syntax match TwiggyUnmerged '\\V\\%1c" .. icons.unmerged .. "'"
  highlight default link TwiggyUnmerged Identifier

  execute "syntax match TwiggyWorktree '\\V\\%1c" .. icons.worktree .. "'"
  highlight default link TwiggyWorktree Special

  syntax match TwiggySortText '\v[[a-z]+]'
  highlight default link TwiggySortText Comment

  if ShowingFullUi()
    syntax match TwiggyHeader "\v%1l^Twiggy" nextgroup=TwiggyHelpHint
    highlight default link TwiggyHeader Title
    syntax match TwiggyHelpHint "\v%1lHelp: " nextgroup = TwiggyHelpHintKey
    highlight default link TwiggyHelpHint fugitiveHelpHeader
    syntax match TwiggyHelpHintKey "\v%1l\g\?" nextgroup=Twiggy9Indicator
    highlight default link TwiggyHelpHintKey fugitiveHelpTag

	const indicator = GetVim9Indicator(true)
    execute($'syntax match Twiggy9Indicator "{indicator}"')
    highlight default link Twiggy9Indicator Comment
  endif

  execute "syntax match TwiggyDetachedText '\\v%3vHEAD\\@[a-z0-9]+'"
  highlight default link TwiggyDetachedText Special

  if exists('branches_not_in_reflog') && len(branches_not_in_reflog) > 0
    execute "syntax match TwiggyNotInReflog '"
        .. Gsub(Gsub(join(branches_not_in_reflog), '\(', ''), '\)', '')
        .. "'"
    highlight default link TwiggyNotInReflog Comment
  endif
enddef

# -----------------------------------------------------------------------------
# Quickhelp / refresh / entry points
# -----------------------------------------------------------------------------
def Quickhelp()
  if &filetype !=# 'twiggy'
    return
  endif

  t:twiggy_cached_git_dir = t:twiggy_git_dir

  silent keepalt edit quickhelp
  setlocal filetype=twiggyqh buftype=nofile bufhidden=delete
  setlocal nonumber nowrap lisp
  if exists('+relativenumber')
    setlocal norelativenumber
  endif
  setlocal modifiable
  execute('silent :1,$delete _')
  b:git_dir = t:twiggy_cached_git_dir
  unlet t:twiggy_cached_git_dir
  var bufnr_ = bufnr('')

  nnoremap <buffer> <silent> g? :Twiggy<CR>

  append(0, QuickhelpView())
  normal! G
  delete _
  normal! gg
  setlocal nomodifiable

  syntax clear
  syntax match TwiggyQuickhelpMapping "\v%<9c[A-Za-z\-\?\^\<\>!,.]"
  highlight link TwiggyQuickhelpMapping Identifier
  syntax match TwiggyQuickhelpSpecial "\v\`[a-zA-Z]+\`"
  highlight link TwiggyQuickhelpSpecial Special
  syntax match TwiggyQuickhelpHeader "\v[A-Za-z ]+\n[=]+"
  highlight link TwiggyQuickhelpHeader Title
  syntax match TwiggyQuickhelpSectionHeader "\v[\-]+\n[[:alnum:],\/ \:]+\n[\-]+"
  highlight link TwiggyQuickhelpSectionHeader String
  syntax match TwiggyQuickhelpGitOption '--[:alnum:][[:alnum:]-]\+$'
  highlight link TwiggyQuickhelpGitOption vimOption

  if g:twiggy_show_full_ui
    syntax match TwiggyQuickhelpRecommendation "\v^\*+\n[[:alnum:]\: ]+\n[a-z\:\- ]+"
    highlight link TwiggyQuickhelpRecommendation String
  endif
enddef

def Refresh()
  if exists('t:refreshing') || !exists('t:twiggy_bufnr') || (!exists('t:twiggy_git_dir') && !exists('b:git_dir'))
    return
  endif

  t:refreshing = 1

  if &filetype !=# 'twiggy'
    if exists('b:git_dir')
      t:twiggy_git_dir = b:git_dir
    endif
    t:twiggy_git_cmd = g:FugitiveShellCommand()
  endif

  var twiggy_winid = bufwinid(t:twiggy_bufnr)

  if &filetype !=# 'twiggy' && exists('*win_execute') && twiggy_winid != -1
    win_execute(twiggy_winid, 'call Render()')
  else
    t:switch_buff = 0
    if &filetype !=# 'twiggy'
      t:old_bufnr = bufnr('')
      t:line = line('.')
      t:col = col('.')
      t:switch_buff = 1
      Buffocus(t:twiggy_bufnr)
    endif

    Render()

    if t:switch_buff
      Buffocus(t:old_bufnr)
      cursor(t:line, t:col)
    endif
  endif

  unlet t:refreshing
enddef

export def Main(...args: list<any>)
  if len(args) == 0
    Branch()
  elseif args[0] ==# 'switch'
    if len(args) < 2
      echo 'Usage: :Twiggy switch BRANCH'
      return
    endif
    call('Branch', args[1 :])
  elseif args[0] ==# 'close'
    CloseOutputBuffer()
  else
    echohl ErrorMsg
    echo 'Unknown Twiggy subcommand: ' .. args[0]
    echohl clear
  endif
enddef

export def Branch(...args: list<any>)
  if len(args)
    var current_branch = GetCurrentBranch()
    var f = BranchExists(args[0]) ? '' : '-c '
    GitCmd('switch ' .. f .. join(args), 0)
    RenderOutputBuffer()
    if exists('t:twiggy_bufnr')
      Refresh()
    endif
    redraw
    echo 'Moved from ' .. current_branch .. ' to ' .. args[0]
  else
    var twiggy_bufnr = exists('t:twiggy_bufnr') ? t:twiggy_bufnr : 0
    if !twiggy_bufnr
      Render()
    else
      if twiggy_bufnr == bufnr('')
        Close()
      else
        t:twiggy_git_dir = b:git_dir
        t:twiggy_git_cmd = g:FugitiveShellCommand()
        Buffocus(t:twiggy_bufnr)
      endif
    endif
  endif
enddef

def Close()
  quit
  redraw
  echo ''
enddef

# -----------------------------------------------------------------------------
# Sorting
# -----------------------------------------------------------------------------
def SortBranches(branch_type: any, int_: any)
  var sorts = get(g:, 'twiggy_' .. branch_type .. '_branch_sorts')
  var sort_name = get(g:, 'twiggy_' .. branch_type .. '_branch_sort')
  var max_index = len(sorts) - int_
  var new_index = index(sorts, sort_name) + int_

  if new_index > max_index
    new_index = 0
  endif

  g:['twiggy_' .. branch_type .. '_branch_sort'] = get(g:, 'twiggy_' .. branch_type .. '_branch_sorts')[new_index]
enddef

def CycleSort(alt: any, int_: any): number
  var local = BranchUnderCursor().is_local
  requires_buf_refresh = 0

  if !alt
    SortBranches(local ? 'local' : 'remote', int_)
  else
    SortBranches(local ? 'remote' : 'local', int_)
  endif

  sorted = 1
  return 0
enddef

def ToggleSlashSort(local: any): number
  if local
    g:twiggy_group_locals_by_slash = g:twiggy_group_locals_by_slash ? 0 : 1
  else
    g:twiggy_group_remotes_by_slash = g:twiggy_group_remotes_by_slash ? 0 : 1
  endif
  return 0
enddef

# -----------------------------------------------------------------------------
# Git actions
# -----------------------------------------------------------------------------
def ShowDirtyTreeOnCheckoutMessage(): void
  var dirty_files = GitCmd('diff --name-only', 0)
  var warning = 'error: Your local changes to the following files would be overwritten by checkout:'
  last_output = [warning]
  extend(last_output, map(dirty_files, (_, val) => "\t" .. val))
  extend(last_output, [
    'Please commit your changes or stash them before you switch branches.',
    'Aborting',
  ])
  v:warningmsg = warning
  RenderOutputBuffer()
enddef

def Checkout(track: any, merge: any): number
  var current_branch = GetCurrentBranch()
  var switch_branch = BranchUnderCursor()
  var merge_opt = merge ? ' --merge ' : ''

  if DirtyTree() && !merge
    ShowDirtyTreeOnCheckoutMessage()
    return 1
  endif

  if track && current_branch ==# switch_branch.fullname
    echo 'Already on ' .. current_branch
    return 1
  else
    redraw
    echo 'Moving from ' .. current_branch .. ' to ' .. switch_branch.fullname .. ellipsis
    if track && !switch_branch.is_local
      if index(map(GitCmd('branch --list', 0), (_, val) => val[2 :]), switch_branch.name) >= 0
        GitCmd('switch ' .. merge_opt .. switch_branch.fullname, 0)
      else
        GitCmd('switch -c ' .. merge_opt .. switch_branch.name .. ' ' .. switch_branch.fullname, 0)
      endif
    elseif !track && !switch_branch.is_local
      GitCmd('switch ' .. merge_opt .. switch_branch.fullname, 0)
    elseif !track && switch_branch.is_local
      GitCmd('switch ' .. merge_opt .. switch_branch.tracking, 0)
    else
      GitCmd('switch ' .. merge_opt .. switch_branch.fullname, 0)
    endif

    if v:shell_error
      RenderOutputBuffer()
      return 1
    endif
  endif

  init_line = 0
  last_branch_under_cursor = 0
  doautocmd User TwiggyCheckout
  fugitive#ReloadStatus()
  return 0
enddef

def CheckoutAs(): number
  var branch = BranchUnderCursor()

  redraw
  var new_name = input('Checkout ' .. branch.name .. ' as: ', '', 'custom,TwiggyCompleteBranches')
  if new_name !=# ''
    if new_name ==# branch.name
      redraw
      echo branch.name .. ' already exists.'
      return 1
    endif
    GitCmd('switch -c ' .. new_name .. ' ' .. branch.fullname, 0)
    redraw
    echo 'Moving from ' .. branch.name .. ' to ' .. new_name .. ellipsis

    init_line = 0
    last_branch_under_cursor = 0

    doautocmd User TwiggyCheckout
    fugitive#ReloadStatus()
    return 0
  endif

  return 1
enddef

def Yank()
  var branch = BranchUnderCursor()
  var reg = empty(v:register) ? '"' : v:register
  setreg(reg, branch.fullname)
enddef

def YankBranches(lnum1: any, lnum2: any)
  var branches = BranchesInRange(lnum1, lnum2)
  var reg = empty(v:register) ? '"' : v:register
  setreg(reg, join(map(copy(branches), (_, val) => val.fullname), "\n"))
enddef

def Delete(): any
  var branch = BranchUnderCursor()

  if branch.fullname ==# GetCurrentBranch()
    return
  endif

  init_line = branch.line

  if branch.is_local
    GitCmd('branch -d ' .. branch.fullname, 0)
    if v:shell_error
      last_output = []
      return Confirm('UNMERGED!  Force-delete local branch ' .. branch.fullname .. '?',
        "GitCmd('branch -D " .. branch.fullname .. "', 0)[0]", 0)
    endif
  else
    return Confirm('Delete remote branch ' .. branch.fullname .. '?',
      "GitCmd('branch -d -r " .. branch.fullname .. "', 0)[0]", 0)
  endif
enddef

def DeleteRemote(): any
  var branch = BranchUnderCursor()
  return Confirm('WARNING! Delete branch ' .. branch.name .. ' from remote repo: ' .. branch.group .. '?',
    "GitCmd('push --delete " .. branch.group .. ' :' .. branch.name .. "', 1)[0]", 0)
enddef

def Fetch(pull: any): number
  var cmd = pull ? 'pull' : 'fetch'
  var branch = BranchUnderCursor()
  if branch.tracking !=# ''
    var remote = split(branch.tracking, '/')[0]
    GitCmd(cmd .. ' ' .. remote .. ' ' .. branch.fullname, 1)
  else
    redraw
    echo branch.name .. ' is not a tracking branch'
    return 1
  endif
  return 0
enddef

def Pull(): number
  return Fetch(1)
enddef

def Merge(remote: any, flags: any): number
  var branch = BranchUnderCursor()

  if remote
    if branch.tracking ==# ''
      v:warningmsg = 'No tracking branch for ' .. branch.fullname
      return 1
    else
      GitCmd('merge ' .. flags .. '  ' .. branch.tracking, 1)
    endif
  else
    if branch.name ==# GetCurrentBranch()
      v:warningmsg = 'Can''t merge into self'
      return 1
    else
      GitCmd('merge ' .. flags .. '  ' .. branch.fullname, 1)
    endif
  endif

  return 0
enddef

def Rebase(remote: any, autostash: any, interactive: any): number
  var branch = BranchUnderCursor()
  var gitcmd = autostash ? 'rebase --autostash ' : 'rebase '
  var dispatch_opts = {}

  if interactive
    gitcmd ..= '-i '
    dispatch_opts.no_dispatch = 1
  endif

  if remote
    if branch.tracking ==# ''
      v:warningmsg = 'No tracking branch for ' .. branch.name
      return 1
    else
      GitCmd(gitcmd .. ' ' .. branch.tracking, 1, dispatch_opts)
    endif
  else
    if branch.fullname ==# GetCurrentBranch()
      v:warningmsg = 'Can''t rebase off of self'
      return 1
    else
      GitCmd(gitcmd .. ' ' .. branch.fullname, 1, dispatch_opts)
    endif
  endif

  return 0
enddef

def Continue(git_type: any)
  if git_type ==? 'stash'
    ContinueStash()
  else
    GitCmd(git_type .. ' --continue', 1, {no_dispatch: 1})
  endif

  redraw
  fugitive#ReloadStatus()
enddef

def Skip()
  GitCmd('rebase --skip', 1, {no_dispatch: 1})
  redraw
  fugitive#ReloadStatus()
enddef

def Abort(git_type: any)
  if git_type ==? 'stash'
    AbortStash()
  else
    GitCmd(git_type .. ' --abort', 0)
  endif
  cclose
  redraw
  echo git_type .. ' aborted'
  fugitive#ReloadStatus()
enddef

def ContinueStash()
  GitCmd('commit', 1, {no_dispatch: 1})
enddef

def AbortStash()
  GitCmd('reset --merge', 0)
enddef

def Push(choose_upstream: any, force: any, set_upstream: any): number
  var branch = BranchUnderCursor()

  if !branch.is_local
    v:warningmsg = "Can't push a remote branch"
    return 1
  endif

  requires_buf_refresh = 0

  var remote_groups = GitCmd('remote', 0)
  var flags = ''
  if force
    flags ..= ' --force-with-lease'
  endif
  if set_upstream
    flags ..= ' --set-upstream'
  endif

  var group: string
  if branch.tracking ==# '' && !choose_upstream
    if g:twiggy_set_upstream
      flags ..= ' -u'
    endif
    if len(remote_groups) > 1
      redraw
      group = input('Push to which remote?: ', '', 'custom,TwiggyCompleteRemotes')
    elseif len(remote_groups) == 0
      redraw
      echo 'There are no remotes to push to'
      return 1
    else
      group = remote_groups[0]
    endif
  else
    if choose_upstream
      redraw
      group = input('Push to which remote?: ', '', 'custom,TwiggyCompleteRemotes')
    else
      group = split(branch.tracking, '/')[0]
    endif
  endif

  if index(remote_groups, group) < 0
    v:warningmsg = 'Remote does not exist'
    return 1
  else
    var cmd = 'push ' .. flags .. ' ' .. group .. ' ' .. branch.fullname
    if !force || !g:twiggy_prompted_force_push
      GitCmd(cmd, 1)
    else
      return Confirm('Force push (with lease) to ' .. branch.tracking .. '?',
        "GitCmd('" .. cmd .. "', 1)", 0)
    endif
  endif

  return 0
enddef

def g:TwiggyCompleteRemotes(A: any, L: any, P: any): string
  var remotes = ''
  for remote in GitCmd('remote', 0)
    if match(remote, '\v^' .. A) >= 0
		remotes = remotes .. remote .. "\n"
    endif
  endfor
  return remotes
enddef

def Rename()
  requires_buf_refresh = 0

  var branch = BranchUnderCursor()
  var new_name = input('Rename ' .. branch.fullname .. ' to: ', branch.fullname)
  redraw
  if !empty(new_name)
    echo 'Renaming "' .. branch.fullname .. '" to "' .. new_name .. '"' .. ellipsis
    GitCmd('branch -m ' .. branch.fullname .. ' ' .. new_name, 0)
    fugitive#ReloadStatus()
  endif
enddef

def Stash(pop: any)
  var pop_arg = pop ? ' pop' : ''
  GitCmd('stash' .. pop_arg, 0)

  redraw
  if !v:shell_error
    echo 'Stash' .. (pop ? ' popped!' : 'ed')
  endif
enddef

# -----------------------------------------------------------------------------
# Fugitive integration
# -----------------------------------------------------------------------------
def CloseString(): string
  if g:twiggy_close_on_fugitive_cmd
    return 'call Close()'
  else
    return 'wincmd w'
  endif
enddef

autocmd BufEnter twiggy://* execute 'command! -buffer Git ' .. CloseString() .. ' | silent <Cmd>Git<CR>'
autocmd BufEnter twiggy://* execute 'command! -buffer Git commit ' .. CloseString() .. ' | silent <Cmd>Git commit<CR>'
autocmd BufEnter twiggy://* execute 'command! -buffer Git blame  ' .. CloseString() .. ' | silent <Cmd>Git blame<CR>'

command! TwiggyRefresh call <ScriptCmd>Refresh()
