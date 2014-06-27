package Complete::Util;

use 5.010001;
use strict;
use warnings;
use Log::Any '$log';

require Exporter;
our @ISA = qw(Exporter);
our @EXPORT_OK = qw(
                       complete_array
                       complete_hash_key
                       complete_env
                       complete_file
                       complete_program

                       mimic_shell_dir_completion
                       break_cmdline_into_words
                       parse_shell_cmdline
                       format_shell_completion
               );

# VERSION
# DATE

our %SPEC;

$SPEC{complete_array} = {
    v => 1.1,
    summary => 'Complete from array',
    args => {
        array => { schema=>['array*'=>{of=>'str*'}], pos=>0, req=>1 },
        word  => { schema=>[str=>{default=>''}], pos=>1 },
        ci    => { schema=>[bool=>{default=>0}] },
    },
    result_naked => 1,
    result => {
        schema => 'array',
    },
};
sub complete_array {
    my %args  = @_;
    my $array = $args{array} or die "Please specify array";
    my $word  = $args{word} // "";
    my $ci    = $args{ci};

    my $wordu = uc($word);
    my @words;
    for (@$array) {
        next unless 0==($ci ? index(uc($_), $wordu) : index($_, $word));
        push @words, $_;
    }
    $ci ? [sort {lc($a) cmp lc($b)} @words] : [sort @words];
}

$SPEC{complete_hash_key} = {
    v => 1.1,
    summary => 'Complete from hash keys',
    args => {
        hash  => { schema=>['hash*'=>{}], pos=>0, req=>1 },
        word  => { schema=>[str=>{default=>''}], pos=>1 },
        ci    => { schema=>[bool=>{default=>0}] },
    },
    result_naked => 1,
    result => {
        schema => 'array',
    },
};
sub complete_hash_key {
    my %args  = @_;
    my $hash  = $args{hash} or die "Please specify hash";
    my $word  = $args{word} // "";
    my $ci    = $args{ci};

    complete_array(word=>$word, array=>[keys %$hash], ci=>$ci);
}

$SPEC{complete_env} = {
    v => 1.1,
    summary => 'Complete from environment variables',
    description => <<'_',

On Windows, environment variable names are all converted to uppercase. You can
use case-insensitive option (`ci`) to match against original casing.

_
    args => {
        word  => { schema=>[str=>{default=>''}], pos=>0 },
        ci    => { schema=>[bool=>{default=>0}] },
    },
    result_naked => 1,
    result => {
        schema => 'array',
    },
};
sub complete_env {
    my %args  = @_;
    my $word  = $args{word} // "";
    my $ci    = $args{ci};
    if ($word =~ /^\$/) {
        complete_array(word=>$word, array=>[map {"\$$_"} keys %ENV], ci=>$ci);
    } else {
        complete_array(word=>$word, array=>[keys %ENV], ci=>$ci);
    }
}

$SPEC{complete_program} = {
    v => 1.1,
    summary => 'Complete program name found in PATH',
    description => <<'_',

Windows is supported, on Windows PATH will be split using /;/ instead of /:/.

_
    args => {
        word  => { schema=>[str=>{default=>''}], pos=>0 },
    },
    result_naked => 1,
    result => {
        schema => 'array',
    },
};
sub complete_program {
    require List::MoreUtils;

    my %args = @_;
    my $word = $args{word} // "";
    my $ci   = $args{ci};

    my $word_re = $ci ? qr/\A\Q$word/i : qr/\A\Q$word/;

    my @res;
    my @dirs = split(($^O =~ /Win32/ ? qr/;/ : qr/:/), $ENV{PATH});
    for my $dir (@dirs) {
        opendir my($dh), $dir or next;
        for (readdir($dh)) {
            push @res, $_ if $_ =~ $word_re && !(-d "$dir/$_") && (-x _);
        };
    }

    [sort(List::MoreUtils::uniq(@res))];
}

$SPEC{complete_file} = {
    v => 1.1,
    summary => 'Complete file and directory from local filesystem',
    args => {
        word => { schema=>[str=>{default=>''}], pos=>0 },
        f    => { summary => 'Whether to include file',
                  schema=>[bool=>{default=>1}] },
        d    => { summary => 'Whether to include directory',
                  schema=>[bool=>{default=>1}] },
    },
    result_naked => 1,
    result => {
        schema => 'array',
    },
};
sub complete_file {
    my %args  = @_;
    my $word  = $args{word} // "";
    my $f     = $args{f} // 1;
    my $d     = $args{d} // 1;

    my @all;
    if ($word =~ m!(\A|/)\z!) {
        my $dir = length($word) ? $word : ".";
        opendir my($dh), $dir or return [];
        @all = map { ($dir eq '.' ? '' : $dir) . $_ }
            grep { $_ ne '.' && $_ ne '..' } readdir($dh);
        closedir $dh;
    } else {
        # must add wildcard char, glob() is convoluted. also {a,b} is
        # interpreted by glob() (not so by bash file completion). also
        # whitespace is interpreted by glob :(. later should replace with a
        # saner one, like wildcard2re.
        @all = glob("$word*");
    }

    my @words;
    for (@all) {
        next if (-f $_) && !$f;
        next if (-d _ ) && !$d;
        $_ = "$_/" if (-d _) && !m!/\z!;
        #s!.+/(.+)!$1!;
        push @words, $_;
    }

    my $w = complete_array(array=>\@words);

    mimic_shell_dir_completion(completion=>$w);
}

# TODO: complete_user (probably in a separate module)
# TODO: complete_group (probably in a separate module)
# TODO: complete_pid (probably in a separate module)
# TODO: complete_filesystem (probably in a separate module)
# TODO: complete_hostname (/etc/hosts, ~/ssh/.known_hosts, ...)
# TODO: complete_package (deb, rpm, ...)

$SPEC{mimic_shell_dir_completion} = {
    v => 1.1,
    summary => 'Make completion of paths behave more like shell',
    description => <<'_',

This function employs a trick to make directory/path completion work more like
shell's own. In shell, when completing directory, the sole completion for `foo/`
is `foo/`, the cursor doesn't automatically add a space (like the way it does
when there is only a single completion possible). Instead it stays right after
the `/` to allow user to continue completing further deeper in the tree
(`foo/bar` and so on).

To make programmable completion work like shell's builtin dir completion, the
trick is to add another completion alternative `foo/ ` (with an added space) so
shell won't automatically add a space because there are now more than one
completion possible (`foo/` and `foo/ `).

_
    args => {
        completion => {
            schema=>'array*',
            req=>1,
            pos=>0,
        },
    },
    result_naked => 1,
    result => {
        schema => 'array',
    },
};
sub mimic_shell_dir_completion {
    my %args  = @_;
    my $c  = $args{completion};
    return $c unless @$c == 1 && $c->[0] =~ m!/\z!;
    [$c->[0], "$c->[0] "];
}

$SPEC{break_cmdline_into_words} = {
    v => 1.1,
    summary => 'Break command-line string into words',
    description => <<'_',

The first step of shell completion is to break the command-line string
(e.g. from COMP_LINE in bash) into words.

Bash by default split using these characters (from COMP_WORDBREAKS):

 COMP_WORDBREAKS=$' \t\n"\'@><=;|&(:'

We don't necessarily want to split using default bash's rule, for example in
Perl we might want to complete module names which contain colons (e.g.
`Module::Path`).

By default, this routine splits by spaces and tabs and takes into account
backslash and quoting. Unclosed quotes won't generate error.

_
    args => {
        cmdline => {
            schema => 'str*',
            req => 1,
            pos => 0,
        },
    },
    result_naked => 1,
    result => {
        schema => 'array*',
    },
};
sub break_cmdline_into_words {
    my %args = @_;
    my $str = $args{cmdline};

    # BEGIN stolen from Parse::CommandLine, with some mods
    $str =~ s/\A\s+//ms;
    $str =~ s/\s+\z//ms;

    my @argv;
    my $buf;
    my $escaped;
    my $double_quoted;
    my $single_quoted;

    for my $char (split //, $str) {
        if ($escaped) {
            $buf .= $char;
            $escaped = undef;
            next;
        }

        if ($char eq '\\') {
            if ($single_quoted) {
                $buf .= $char;
            } else {
                $escaped = 1;
            }
            next;
        }

        if ($char =~ /\s/) {
            if ($single_quoted || $double_quoted) {
                $buf .= $char;
            } else {
                push @argv, $buf if defined $buf;
                undef $buf;
            }
            next;
        }

        if ($char eq '"') {
            if ($single_quoted) {
                $buf .= $char;
                next;
            }
            $double_quoted = !$double_quoted;
            next;
        }

        if ($char eq "'") {
            if ($double_quoted) {
                $buf .= $char;
                next;
            }
            $single_quoted = !$single_quoted;
            next;
        }

        $buf .= $char;
    }
    push @argv, $buf if defined $buf;

    #if ($escaped || $single_quoted || $double_quoted) {
    #    die 'invalid command line string';
    #}
    \@argv;
    # END stolen from Parse::CommandLine
}

$SPEC{parse_shell_cmdline} = {
    v => 1.1,
    summary => 'Parse shell command-line for processing by completion routines',
    description => <<'_',

Currently only supports bash.

Returns hash with the following keys: `words` (array of str, equivalent to
`COMP_WORDS` provided by shell to completion routine), `cword` (int, equivalent
to shell-provided `COMP_CWORD`).

_
    args_as => 'array',
    args => {
        cmdline => {
            summary => 'Command-line, defaults to COMP_LINE environment',
            schema => 'str*',
            pos => 0,
        },
        point => {
            summary => 'Point/position to complete in command-line, '.
                'defaults to COMP_POINT',
            schema => 'int*',
            pos => 1,
        },
    },
    result_naked => 1,
    result => {
        schema => [hash => {keys => {
            words=>['array*' => of => 'str*'],
            cword=>'int*',
        }}],
    },
};
sub parse_shell_cmdline {
    my ($line, $point) = @_;

    $line  //= $ENV{COMP_LINE};
    $point //= $ENV{COMP_POINT};

    my $left  = substr($line, 0, $point);
    my $right = substr($line, $point);
    $log->tracef("line=<%s>, point=%s, left=<%s>, right=<%s>",
                 $line, $point, $left, $right);

    my @left;
    if (length($left)) {
        @left = @{ break_cmdline_into_words(cmdline=>$left) };
        # shave off $0
        substr($left, 0, length($left[0])) = "";
        $left =~ s/^\s+//;
        shift @left;
    }

    my @right;
    if (length($right)) {
        # shave off the rest of the word at "cursor"
        $right =~ s/^\S+//;
        @right = @{ break_cmdline_into_words(cmdline=>$right) }
            if length($right);
    }
    $log->tracef("\@left=%s, \@right=%s", \@left, \@right);

    my $words = [@left, @right],
    my $cword = @left ? scalar(@left)-1 : 0;

    # is there a space after the final word (e.g. "foo bar ^" instead of "foo
    # bar^" or "foo bar\ ^")? if yes then cword is on the next word.
    my $tmp = $left;
    my $nspc_left = 0; $nspc_left++ while $tmp =~ s/\s$//;
    $tmp = $left[-1];
    my $nspc_lastw = 0;
    if (defined($tmp)) { $nspc_lastw++ while $tmp =~ s/\s$// }
    $cword++ if $nspc_lastw < $nspc_left;

    my $res = {words => $words, cword => $cword};
    $res;
}

$SPEC{format_shell_completion} = {
    v => 1.1,
    summary => 'Format completion for output to shell',
    description => <<'_',

Usually, like in bash, we just need to output the entries one line at a time,
with some special characters in the entry escaped using backslashes so it's not
interpreted by the shell.

_
    args_as => 'array',
    args => {
        shell_completion => {
            summary => 'Result of shell completion',
            description => <<'_',

A hash containing list of completions and other metadata. For example:

    {
        completion => ['f1', 'f2', 'f3.txt', 'foo:bar.txt'],
        type => 'filename',
    }

_
            schema=>'hash*',
            req=>1,
            pos=>0,
        },
    },
    result => {
        schema => 'str*',
    },
    result_naked => 1,
};
sub format_shell_completion {
    my ($shcomp) = @_;

    $shcomp //= {};
    my $comp = $shcomp->{completion} // [];

    my @lines;
    for (@$comp) {
        my $str = $_;
        $str =~ s!([^A-Za-z0-9,+._/\$-])!\\$1!g;
        push @lines, $str;
        $str .= "\n";
    }
    join("", @lines);
}

1;
# ABSTRACT: Shell completion routines

=head1 DESCRIPTION

This module provides routines for doing programmable shell tab completion.
Currently this module is geared towards bash, but support for other shells might
be added in the future (e.g. zsh, fish).

The C<complete_*()> routines are used to complete from a specific data source or
for a specific type. They are the lower-level functions.


=head1 DEVELOPER'S NOTES

We want to future-proof the API so future features won't break the API (too
hardly). Below are the various notes related to that.

In fish, aside from string, each completion alternative has some extra metadata.
For example, when completing filenames, fish might show each possible completion
filename with type (file/directory) and file size. When completing options, it
can also display a summary text for each option. So instead of an array of
strings, array of hashrefs will be allowed in the future:

 ["word1", "word2", "word3"]
 [ {word=>"word1", ...},
   {word=>"word2", ...},
   {word=>"word3", ...}, ]

fish also supports matching not by prefix only, but using wildcard. For example,
if word if C<b??t> then C<bait> can be suggested as a possible completion. fish
also supports fuzzy matching (e.g. C<house> can bring up C<horse> or C<hose>).
There is also spelling-/auto-correction feature in some shells. This feature can
be added later in the various C<complete_*()> routines. Or there could be helper
routines for this. In general this won't pose a problem to the API.

fish supports autosuggestion (autocomplete). When user types, without she
pressing Tab, the shell will suggest completion (not only for a single token,
but possibly for the entire command). If the user wants to accept the
suggestion, she can press the Right arrow key. This can be supported later by a
function e.g. C<shell_complete()> which accepts the command line string.
