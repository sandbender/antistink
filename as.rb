#!/usr/bin/ruby

require 'rubygems'

require 'logger'
require 'yaml'
require 'git'
require 'net/smtp'


### start config

author        = 'onelove'
author_email  = 'rudy@sandbenders.ca' # for alerts
from_name     = 'Antistink'
from_email    = 'rudy@sandbenders.ca'
uri           = '/grid/code/apps/sites/antistink/test_target'
start_version = '1f11ee9d66e2a26a844499cff83d0479405ee633'

# you don't technically need to change anything beyond here

#sleep_seconds = 600 # ten minutes by default
sleep_seconds = 10 # 10 seconds for testing/debugging

debug = 0

### end config

sig_hup  = false # don't change this initialization - this is a flag for signal handling
sig_term = false


def parse_removed_line_boundaries(git_diff_file)
  return parse_added_line_boundaries(git_diff_file, true)
end

def parse_added_line_boundaries(git_diff_file, removed = false)
  scan_ready = false
  last_non_blank = nil
  state = false

  changed_lines = []

  regex = removed ? /^-/ : /^\+/
  iregex = removed ? /^\+/ : /^-/

  pos = 1

  git_diff_file.patch.each_line do |line|
    # step through the lines of the diff patch, and save / derive what we need

    # need the trailing .*$ because diff/git-diff includes the preceding line
    # immediately after the line index spec except the first time
    #
    # ie:
    #
    # @@ -1,2 +1,1 @@
    #  line one
    # -line two
    # @@ -8,2 +7,1 @@ line seven
    #  line eight
    # -line nine
    #
    # (notice line #7 is included on the same line as the second 'diff index' line
    #
    if line.match(/^@@ -[0-9]+,[0-9]+ \+[0-9]+,[0-9]+ @@.*$/)
      changed_lines << [state, pos] if state

      scan_ready = true
      state = false 

      line.sub!(/^@@ -/, '')
      pos = line.sub(/,.*$/, '').to_i

      pos -= 1

      last_non_blank = (pos > 0) ? pos : 1
    elsif scan_ready
      if regex.match(line)
        pos += 1 if removed

        state = last_non_blank if (! state)
      elsif ! removed || ! iregex.match(line)
        pos += 1

        last_non_blank = pos if (! /^\s*$/.match(line))

        if state
          changed_lines << [state, pos]

          state = false
        end
      end
    end
  end

  changed_lines << [state, pos] if state

  return changed_lines
end

def reduce_range_array(arr, input_is_ordered = true)
  if 1 >= arr.length
    return arr
  end

  arrsize = arr.length

  cnt = 1

  while cnt < arrsize
    el = arr.shift

    i = 0

    while i < (arrsize - cnt)

      # sanity

      if el[0] > el[1] || arr[i][0] > arr[i][1]
        raise "Can't have a start range idx greater then end range idx!"
      end

      # meat

      if el[0] <= (arr[i][1] + 1) && el[1] >= (arr[i][0] - 1)

        # these ranges overlap or are adjacent

        arr[i][0] = el[0] if (el[0] < arr[i][0])
        arr[i][1] = el[1] if (el[1] > arr[i][1])

        # recursion

        return reduce_range_array(arr, input_is_ordered)
      elsif el[0]
      end

      i += 1
    end

    # no overlap - push current element onto the end, and loop

    arr << el

    cnt += 1
  end

  # if we get here, it means we have more than one element in the array, and we're
  # done trying to reduce it... if the input was ordered, we should be able to
  # shift-push once more and return an array that's ordered in addition to reduced

  input_is_ordered && arr << arr.shift

  return arr
end


git = Git.open(uri, 1 < debug ? {:log => Logger.new(STDOUT)} : {})

# @todo do some git repo initialization checking here (ie: make sure we can read, etc)

pid = fork do
  Signal.trap("HUP") do
    debug && print("Caught SIG HUP... exiting gracefully...\n")

    sig_hup = true
  end
  Signal.trap("TERM") { sig_term = true }

  until sig_hup || sig_term
    reset_start = true

    commits_to_notify = {}

    git.log.between(start_version).each do |commit|
      if reset_start
        reset_start = false

        start_version = commit.sha
      end

      if commit.author.name != author
        puts "checking commit " + commit.sha if debug > 0

        # do check for possible stinky changes 

        commit.parent.diff(commit).each do |file|
          puts "file path: " + file.path if debug > 0

          added_lines = parse_added_line_boundaries(file)
          removed_lines = parse_removed_line_boundaries(file)

          changed_lines = added_lines.concat(removed_lines)
          changed_lines = reduce_range_array(changed_lines, false)

          # just in case, although if git/ruby-git are sane, this conditional isn't necessary

          if 0 < changed_lines.length

            # now that we have a set of changed lines to examine, we can use git-blame to find
            # the authors of those lines in the previous commit (this commit's parent), and
            # check if it's the author we're monitoring... if so, then we want to notify the
            # author that their code or adjacent code has been modified

            blame_opts = {:rev => commit.parent.sha}

            blame = git.blame(file.path, blame_opts)

            changed_lines.each do |range|
              for i in range[0]..range[1]
                if blame.lines[i] \
                && blame.lines[i].author == author
                  if ! commits_to_notify[commit.sha]
                    commits_to_notify[commit.sha] = {}
                  end

                  if ! commits_to_notify[commit.sha][file.path]
                    commits_to_notify[commit.sha][file.path] = {:lines => [], :patch => file.patch}
                  end

                  commits_to_notify[commit.sha][file.path][:lines] << [i, i]
                  commits_to_notify[commit.sha][:commit] = commit if (! commits_to_notify[commit.sha][:commit])
                end
              end
            end

            if commits_to_notify[commit.sha] \
            && commits_to_notify[commit.sha][file.path]
              commits_to_notify[commit.sha][file.path][:lines] = reduce_range_array(commits_to_notify[commit.sha][file.path][:lines], true)
            end
          end
        end
      end
    end

    # SEND NOTIFICATIONS!

    if 0 < commits_to_notify.length
      commits_to_notify.each do |sha, fileh|
        out = "#{fileh[:commit].author.name} <#{fileh[:commit].author.email}> has been changing your code (in commit #{sha})!\n\n"
        out << "The following lines detail which files they changed, followed by which of YOUR lines were affected, from commit #{fileh[:commit].parent.sha} ...\n\n"

        # file_two.code: lines lines-1177

        fileh.each do |file, hash|
          if file != :commit
            out << "###\n"
            out << '### ' + file + ': lines '

            linespec = []

            hash[:lines].each do |range|
              spec = range[0].to_s

              spec << '-' + range[1].to_s if (range[0] != range[1])

              linespec << spec
            end

            out << linespec.join(', ')
            out << "\n###\n\n"

            out << hash[:patch] + "\n--\n\n"
          end
        end

        out << "\nSincerely, the Antistink.com daemon"

        puts out if debug > 0

        Net::SMTP.start('localhost', 25) do |smtp|
          msg_head = <<EOM
From: #{from_name} <#{from_email}>
To: #{author} <#{author_email}>
Subject: Your code has been affected by commit #{sha}

EOM

          msg = msg_head + out

          smtp.send_message msg, from_email, author_email
        end
      end
    end
  
    sleep sleep_seconds
  end
end

debug && print('Started antistinker with pid ', pid, "\n")

Process.detach(pid)

