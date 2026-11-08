# Instructions for Claude

## Commits and pull requests

No attribution, ever: no `Co-Authored-By: Claude …` trailer, no `Claude-Session:` trailer or claude.ai session link, no
"Generated with Claude Code" line, in commit messages, tags or pull request descriptions. The author is the repository's owner
alone. (`.claude/settings.json` sets `attribution` the same way; this rule stands even where that file is not read.)

Author and committer of every commit: `sachahjkl <sacha@sacha.house>`, never `Claude <noreply@anthropic.com>` nor any other name.
Where the environment sets another identity (a cloud session does), commit with
`git -c user.name=sachahjkl -c user.email=sacha@sacha.house commit …` and with `GIT_COMMITTER_NAME=sachahjkl` and
`GIT_COMMITTER_EMAIL=sacha@sacha.house` set, and check `git log -1 --format='%an <%ae> / %cn <%ce>'` before pushing.
