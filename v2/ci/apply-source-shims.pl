#!/usr/bin/env perl
# Apply the source-level fixes in v2/ci/source-shims.tsv to a fetched tree.
#
#   v2/ci/apply-source-shims.pl <shims.tsv> <tree-root>
#
# Where this sits relative to the other two shim passes, because the distinction
# matters when something does not work:
#
#   isa-shims.txt     changes the ISA level the compiler targets
#   source-shims.tsv  fixes defects in the upstream source itself
#   script-shims.tsv  fixes debian/ maintainer scripts that break when a
#                     dependency was removed by dep-shims.pl
#
# Shim file format: "<path>\t<literal from>\t<literal to>", one per line.
# The path is relative to the tree root and is treated as a glob, because the
# PikaOS recipes copy themselves into a subdirectory before building
# (main.sh does `cp -rvf ./* ./<name>/`), so the same file can be at either
# src/main.rs or <name>/src/main.rs depending on how far the recipe got.
use strict;
use warnings;

my ($shim_file, $root) = @ARGV;
die "usage: $0 <shims.tsv> <tree-root>\n" unless $shim_file && $root;
die "$shim_file: missing\n" unless -f $shim_file;
die "$root: not a directory\n" unless -d $root;

my @rules;
open my $sfh, '<', $shim_file or die "$shim_file: $!\n";
while (my $line = <$sfh>) {
    next if $line =~ /^\s*(#|$)/;
    chomp $line;
    my ($path, $from, $to) = split /\t/, $line, 3;
    next unless defined $path && defined $from && defined $to;
    for ($path, $from, $to) { s/^\s+|\s+$//g }
    die "$shim_file: malformed rule (need 3 tab-separated fields): $line\n"
      unless length $path && length $from;
    push @rules, { path => $path, from => $from, to => $to };
}
close $sfh;
die "$shim_file: no active rules\n" unless @rules;

# Expand a relative glob against the tree root. Avoids pulling in a module for
# one glob: if the pattern has no metacharacter, use it directly.
sub matches_file {
    my ($pattern, $abs) = @_;
    return 1 if $pattern eq $abs;
    return 0 if $pattern =~ /[*?\[]/;
    # No metacharacter: treat the pattern as a path relative to the root and
    # check every path component, so "src/main.rs" matches
    # "pika-drivers/src/main.rs" as well as "src/main.rs".
    my @want = split m{/}, $pattern;
    my @have = split m{/}, $abs;
    return 0 if @have < @want;
    my @tail = @have[ -@want .. -1 ];
    return join('/', @tail) eq join('/', @want);
}

my $applied = 0;
my $matched_files = 0;

for my $r (@rules) {
    # Find candidates: walk the tree once per rule, but only under paths that
    # could plausibly match, and skip the build output and VCS metadata.
    my @hits;
    my @stack = ($root);
    while (my $dir = shift @stack) {
        opendir my $dh, $dir or next;
        my @entries = grep { $_ ne '.' && $_ ne '..' } readdir $dh;
        closedir $dh;
        for my $e (@entries) {
            next if $e eq '.git' || $e eq 'target' || $e eq '.cargo';
            my $abs = "$dir/$e";
            if (-l $abs) { next }             # don't rewrite through symlinks
            if (-d $abs) { push @stack, $abs; next }
            push @hits, $abs if matches_file($r->{path}, $abs);
        }
    }

    unless (@hits) {
        # Not an error. Many packages simply do not contain the file a rule
        # targets, and the pika-device-manager case is deliberate: its upstream
        # already has the fix, so the rule must not match it.
        print STDERR "source-shims: no file matches '$r->{path}' for '$r->{from}' (already correct upstream?)\n";
        next;
    }

    for my $file (@hits) {
        open my $fh, '<', $file or next;
        my $text = do { local $/; <$fh> };
        close $fh;
        my $n = ($text =~ s/\Q$r->{from}\E/$r->{to}/g);
        next unless $n;
        open my $ofh, '>', $file or die "$file: $!\n";
        print $ofh $text;
        close $ofh;
        $applied += $n;
        $matched_files++;
        print STDERR "source-shims: $file: rewrote $n occurrence(s)\n";
    }
}

print STDERR "source-shims: applied $applied rewrite(s) in $matched_files file(s)\n";
exit 0;