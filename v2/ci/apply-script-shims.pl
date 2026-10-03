#!/usr/bin/env perl
# Make a PikaOS package's maintainer scripts survive having its PikaOS-only
# dependencies stripped out by apply-dep-shims.pl.
#
#   v2/ci/apply-script-shims.pl <shims.tsv> <maintainer-script>...
#
# Dropping a dependency and running the package's own postinst are the same
# change seen from two sides, and only the first was handled. The concrete case:
#
#   pika-device-manager's debian/postinst ends with
#
#       chmod -R 777 /var/cache/cfhdb/
#
# cfhdb is a PikaOS-only hardware database, so dep-shims.tsv drops it from
# Depends (there is no Debian package to depend on). Nothing creates
# /var/cache/cfhdb, so chmod fails, `set -e` propagates it, and dpkg leaves the
# package half-configured:
#
#   dpkg: error processing package pika-device-manager (--configure):
#    the subprocess old pika-device-manager maintainer script postinst failed
#    with error code 1
#
# The package itself is fine -- only the post-install hook assumes a package we
# deliberately removed. So this does the other half of the job: rewrite the
# hook so it tolerates the absence, rather than restoring the dependency or
# leaving the install broken.
#
# Format of the shim file: "<substring to find>\t<replacement>", one per line.
# Blank lines and '#' comments are ignored. Matching is literal, not regex.
use strict;
use warnings;

my ($shim_file, @files) = @ARGV;
die "usage: $0 <shims.tsv> <maintainer-script>...\n" unless $shim_file && @files;

my @rules;
open my $sfh, '<', $shim_file or die "$shim_file: $!\n";
while (my $line = <$sfh>) {
    next if $line =~ /^\s*(#|$)/;
    chomp $line;
    my ($from, $to) = split /\t/, $line, 2;
    next unless defined $from && defined $to;
    $from =~ s/^\s+|\s+$//g;
    push @rules, [$from, $to];
}
close $sfh;
die "$shim_file: no active rules\n" unless @rules;

my $hits = 0;
for my $file (@files) {
    open my $fh, '<', $file or die "$file: $!\n";
    my $text = do { local $/; <$fh> };
    close $fh;

    my $before = $text;
    for my $r (@rules) {
        my ($from, $to) = @$r;
        my $n = ($text =~ s/\Q$from\E/$to/g);
        if ($n) {
            $hits += $n;
            print STDERR "script-shims: $file: rewrote $n occurrence(s)\n";
        }
    }
    next if $text eq $before;

    open my $ofh, '>', $file or die "$file: $!\n";
    print $ofh $text;
    close $ofh;
}

print STDERR "script-shims: applied $hits rewrite(s)\n";
exit 0;