#!/bin/bash

. "$(dirname "$0")"/../gettext/gettext.sh

set -u -e

data_dir=$(dirname "$0")/data
vocab_dir=$(dirname "$0")/vocabulary

irc_command='!quiz'

user=$DMB_SENDER
channel_name=${DMB_RECEIVER-}

query="$*"
# Strip whitespace.
query="$(printf '%s\n' "$query" | sed 's/\(^[ 　]*\|[ 　]*$\)//g')"

[[ -d $data_dir ]] || mkdir -p "$data_dir"
[[ -d $vocab_dir ]] || mkdir -p "$vocab_dir"

if [[ ! $user ]]; then
    printf_ 'Could not determine nick name. Please fix %s.' '$user'
    exit 1
fi
if [[ ! $channel_name ]]; then
    printf_ 'Could not determine channel name or query sender. Please fix %s.' '$channel_name'
    exit 1
fi

timer_file="$data_dir/timer.key.$channel_name"
stats_db="$data_dir/stats.db"
question_file="$data_dir/question.status.$channel_name"

# Checks if $1 is a valid level.
check_level() {
    [[ -s $vocab_dir/$1.txt ]]
}

# Starts a timer. Delay in seconds is $1.
set_timer() {
    local timer_key=$RANDOM$RANDOM$RANDOM$RANDOM
    echo "$timer_key" > $timer_file
    echo "/timer $1 $timer_key"
}

# $1 is the level. Loads a random line out that list.
load_source_line() {
    sort --random-sort "$vocab_dir/$1.txt" | head -n 1
}

split_lines() {
    kanji=$(printf '%s\n' "$1" | head -n 1)
    readings=$(printf '%s\n' "$1" | head -n 2 | tail -n 1)
    meaning=$(printf '%s\n' "$1" | head -n 3 | tail -n 1)
}

# $1 is the level. Returns non-zero on invalid levels.
ask_question() {
    check_level "$1" || return 1
    local source=$(load_source_line "$1")
    split_lines "${source//|/$'\n'}"
    printf '%s\n%s\n%s\n%s\n' "$kanji" "$readings" "$meaning" "$1" > "$question_file"
    printf_ 'Please read: %s' "$kanji"
}

sql() {
    sqlite3 "$stats_db" "$1" 2> /dev/null
}

initialize_database() {
    sql 'CREATE TABLE IF NOT EXISTS user_stats (
user NOT NULL,
word NOT NULL,
correct NOT NULL,
timestamp NOT NULL DEFAULT CURRENT_TIMESTAMP );'
    # correct used to be an integer column.  Upgrade old databases.
    sql "UPDATE user_stats SET correct = 'wrong' WHERE correct = 0;"
    sql "UPDATE user_stats SET correct = 'correct' WHERE correct = 1;"
}

# $1 should be one of 'wrong', 'correct', 'skipped'
record_answer() {
    initialize_database
    sql "INSERT INTO user_stats (user, word, correct) VALUES ('$user', '$kanji', '$1');"
}

get_user_stats() {
    initialize_database
    local stats=$(sql "SELECT correct,COUNT(*) FROM user_stats WHERE user = '$1'
AND julianday(timestamp) > julianday('now', '-2 month')
GROUP BY correct ORDER BY correct ASC;")
    local wrong=$(echo "$stats" | grep -m 1 '^wrong|' | sed 's/^wrong|//')
    local correct=$(echo "$stats" | grep -m 1 '^correct|' | sed 's/^correct|//')
    local skipped=$(echo "$stats" | grep -m 1 '^skipped|' | sed 's/^skipped|//')
    if [[ ! $wrong && ! $correct && ! $skipped ]]; then
        printf_ 'Unknown user: %s' "$1"
        return 1
    fi
    wrong=${wrong:-0}
    correct=${correct:-0}
    skipped=${skipped:-0}
    local total=$(( $wrong + $correct + $skipped ))
    local correct_percentage=$(echo "scale=2; $correct * 100 / ($total)" | bc)
    local skipped_percentage=$(echo "scale=2; $skipped * 100 / ($total)" | bc)
    printf_ 'In the last 2 months, %s answered %s/%s (%s%%) questions correctly and skipped %s/%s (%s%%).' \
        "$1" "$correct" "$total" "$correct_percentage" "$skipped" "$total" "$skipped_percentage"
    local hard_words=$(sql "
        SELECT u.word,ifnull(wrong,0) AS wrong0, ifnull(skipped,0) AS skipped0
        FROM user_stats AS u
            LEFT JOIN
                (SELECT word AS w, COUNT(*) AS wrong FROM user_stats WHERE correct = 'wrong' GROUP BY word)
                ON u.word = w
            LEFT JOIN
                (SELECT word AS s, COUNT(*) AS skipped FROM user_stats WHERE correct = 'skipped' GROUP BY word)
                ON u.word = s
        WHERE user = '$1'
            AND julianday(timestamp) > julianday('now', '-2 month')
            AND (wrong0 != 0 OR skipped0 != 0)
        GROUP BY word
        ORDER BY wrong0 + skipped0 DESC
        LIMIT 10;" | \
        sed 's/^\([^|]*\)|\([^|]*\)|\(.*\)$/\1 (\2\/\3)/')
    [[ $hard_words ]] && printf_ 'Hardest words for %s (#mistakes/#skipped): %s' \
        "$1" "${hard_words//$'\n'/, }"
}

# Checks if $1 is a correct answer.
check_if_answer() {
    if [[ ! -s $question_file ]]; then
        echo_ 'Please specify a level.'
        return
    fi
    local proposed="${1// /}"
    split_lines "$(cat "$question_file")"
    local IFS=','
    for r in $readings; do
        if [[ $r = $proposed ]]; then
            ### The argument order is $user $readings $meaning
            printf_ '%s: Correct! (%s: %s)' "$user" "$readings" "$meaning"
            record_answer 'correct'
            # Ignore additional answers for a few seconds.
            set_timer 2
            return 0
        fi
    done
    printf_ '%s: Sadly, no.' "$user"
    record_answer 'wrong'
}

# Handle the help command.
if [[ ! $query || $query = 'help' ]]; then
    printf_ 'Try "%s jlpt4". With "%s skip" you can skip questions.' "$irc_command" "$irc_command"
    printf_ 'Statistics can be accessed by "%s stats <nickname>".' "$irc_command"
    exit 0
fi

# Handle the stats command.
if printf '%s\n' "$query" | grep -q '^stats'; then
    if printf '%s\n' "$query" | grep -q '^stats \+[][a-zA-Z0-9|_-`]\+$'; then
        get_user_stats "$(printf '%s\n' "$query" | sed 's/^stats \+//')"
    else
        printf_ 'Usage: %s stats <nickname>' "$irc_command"
    fi
    exit 0
fi

# Handle the timer.
if [[ -s $timer_file ]]; then
    if [[ ! $(find "$timer_file" -cmin 1) ]]; then
        rm "$timer_file"
    else
        # The timer is running, so ignore answers.
        if [[ $(cat "$timer_file") = $query ]]; then
            rm "$timer_file"
            # The timer expired. Ask next question.
            ask_question "$(tail -n 1 "$question_file")"
        fi
        exit 0
    fi
fi

# Handle the skip/next command.
if printf '%s\n' "$query" | grep -q '^\(next\|skip\) *$'; then
    # Display answer and skip current question.
    if [[ ! -s $question_file ]]; then
        echo_ 'Nothing to skip!'
        exit 0
    fi
    split_lines "$(cat "$question_file")"
    printf_ 'Skipping %s (%s: %s)' "$kanji" "$readings" "$meaning"
    record_answer 'skipped'
    set_timer 2
    exit 0
fi

# Handle answers.
if echo "$query" | LC_ALL=C grep -vq '^[a-zA-Z0-9 -]\+$'; then
    # $query contains non-latin characters or characters unsafe for a
    # filename, so assume it's an answer.
    check_if_answer "$query"
    exit 0
fi

# The only remaining possibility is that $query contains a level.
if ! ask_question "$query"; then
    for level in "$vocab_dir"/*.txt; do
        base_name="$(basename "$level" | sed 's/\.txt$//')"
        line_count="$(wc -l "$level" | cut -d ' ' -f 1)"
        valid_levels="${valid_levels:+$valid_levels$'\n'}$base_name ($line_count)"
    done
    printf_ 'Unknown level "%s". Valid levels (number of words): %s' \
        "$query" "${valid_levels//$'\n'/, }"
fi

exit 0
