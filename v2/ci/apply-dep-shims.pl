#!/usr/bin/env perl
# Rewrite KF5 / PikaOS-only dependencies out of a package's control files so
# the rebuilt package installs on a KF6 Debian sid base.
#
#   v2/ci/apply-dep-shims.pl <shims.tsv> <control-file>...
#
# The shim file is the TSV from v2/ci/dep-shims.tsv: "<name>\t<action>", where
# an action of "-" drops the dependency and anything else renames it, keeping
# any version or architecture constraint. Only dependency-list fields are
# touched; Description, Maintainer and friends are never modified, and folded
# continuation lines of a dependency list are handled as one logical line.
use strict;
use warnings;

my ($shim_file, @files) = @ARGV;
die "usage: $0 <shims.tsv> <control-file>...\n" unless $shim_file && @files;

my %shim;
open my $sfh, '<', $shim_file or die "$shim_file: $!\n";
while (my $line = <$sfh>) {
    next if $line =~ /^\s*(#|$)/;
    chomp $line;
    my ($name, $action) = split /\t/, $line, 2;
    next unless defined $name && defined $action;
    $name   =~ s/^\s+|\s+$//g;
    $action =~ s/^\s+|\s+$//g;
    $shim{$name} = $action if length $name && length $action;
}
close $sfh;

my @FIELDS = qw(
    Depends Pre-Depends Recommends Suggests Enhances Breaks Conflicts
    Replaces Provides
);
my $field_re = join '|', @FIELDS;

my $dropped = 0;

for my $file (@files) {
    open my $in, '<', $file or die "$file: $!\n";
    my @out;
    my $pending;

    while (defined(my $line = defined $pending ? do { (my $p = $pending) =~ s/\z//; $pending = undef; $p } : <$in>)) {
        $pending = undef;
        if ($line =~ /^(?:$field_re)\s*:\s*(.*)$/s) {
            my ($field, $rest) = ($&, $1);
            $field =~ s/\s*:.*//s;

            # Absorb folded continuation lines.
            while (defined(my $nxt = <$in>)) {
                if ($nxt =~ /^[ \t]\S/) {
                    $rest .= ' ' . $nxt;
                } else {
                    $pending = $nxt;
                    last;
                }
            }

            my @deps;
            for my $dep (split /,/, $rest) {
                $dep =~ s/^\s+|\s+$//g;
                next unless length $dep;

                # A dependency name can never contain a space, so a space
                # inside a chunk always means upstream lost a comma.
                # pika-meta ships "mesa-vulkan-drivers:i386 mesa-vulkan-drivers"
                # like that and dpkg-gencontrol rejects the whole file. Peel
                # off one complete entry at a time (name, optional
                # ":qualifier", optional "(constraint)", optional "| alts").
                my @candidates;
                my $rest2 = $dep;
                while ($rest2 =~ s{^([A-Za-z0-9][A-Za-z0-9+.-]*(?::[A-Za-z0-9]+)?(?:\s*\([^)]*\))?(?:\s*\|\s*[A-Za-z0-9][A-Za-z0-9+.-]*(?::[A-Za-z0-9]+)?)*)\s+(?=[A-Za-z0-9])}{}) {
                    push @candidates, $1;
                    $rest2 =~ s/^\s+//;
                }
                push @candidates, $rest2 if length $rest2;

                for my $cand (@candidates) {
                    if ($cand =~ /^([A-Za-z0-9][A-Za-z0-9+.-]*)/) {
                        my $name = $1;
                        if (exists $shim{$name}) {
                            my $action = $shim{$name};
                            if ($action eq '-') {
                                $dropped++;
                                next;
                            }
                            $cand =~ s/^\Q$name\E/$action/;
                        }
                    }
                    push @deps, $cand;
                }
            }
            # An emptied dependency field is dropped entirely rather than
            # left as a bare "Field:", which some tooling dislikes.
            push @out, "$field: " . join(', ', @deps) . "\n" if @deps;
            next;
        }
        push @out, $line;
    }
    close $in;

    open my $ofh, '>', $file or die "$file: $!\n";
    print $ofh @out;
    close $ofh;
}

print STDERR "dep-shims: dropped $dropped dependenc(y|ies)\n";
exit 0;