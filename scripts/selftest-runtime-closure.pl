#!/usr/bin/perl
# Every file hlstats.pl loads through $opt_libdir must be committed here.
#
# Why this exists: the repo shipped for months with `require
# "$opt_libdir/ConfigReaderSimple.pm"` and no such file, because production's
# /opt/hlstatsx already held the upstream libraries and nothing else ever
# started the daemon from a bare checkout. A CI harness that built from the
# repo alone then failed on a line no commit had touched.
#
# The list is DERIVED from the source and walked transitively, never hardcoded:
# a hardcoded list is a second thing to keep in sync, and it rots toward
# passing. `require` dies on a missing file and `do` only warns, so a gap in
# the `do` set is the quieter half and is exactly what this catches.
use strict;
use warnings;
use Test::More;
use File::Basename qw(dirname);
use File::Temp qw(tempdir);
use File::Spec;

# $opt_libdir is spelled bare in the entrypoint and package-qualified inside the
# libraries; both forms name the same directory. \r?-tolerant because this tree
# checks out CRLF on Windows while the deployed copy is LF.
my $LOAD = qr/^\s*(?:require|do)\s+"\$(?:::)?opt_libdir\/([\w.]+)"/m;

# Returns (\%missing_name_to_referrer, \@reached) for the closure rooted at
# $entry inside $dir. Takes both as arguments so the discrimination check below
# can run it against a synthetic tree instead of trusting it on the real one.
sub closure {
    my ($dir, $entry) = @_;
    my (%seen, %missing, @queue);
    @queue = ([$entry, '<entrypoint>']);
    while (my $next = shift @queue) {
        my ($name, $from) = @$next;
        next if $seen{$name}++;
        my $path = File::Spec->catfile($dir, $name);
        unless (-f $path) {
            $missing{$name} = $from;
            next;
        }
        open(my $fh, '<', $path) or die "cannot read $path: $!";
        local $/;
        my $src = <$fh>;
        close($fh);
        push @queue, [$_, $name] for $src =~ /$LOAD/g;
    }
    delete $seen{$entry};
    return (\%missing, [sort keys %seen]);
}

# --- the check discriminates -------------------------------------------------
# A closure check that can only pass proves nothing. Prove it reports a gap
# before believing that it reports none.
{
    my $tmp = tempdir(CLEANUP => 1);
    open(my $fh, '>', File::Spec->catfile($tmp, 'fake.pl')) or die $!;
    print $fh qq{require "\$opt_libdir/Present.pm";\n},
              qq{do "\$opt_libdir/Absent.plib";\n};
    close($fh);
    open($fh, '>', File::Spec->catfile($tmp, 'Present.pm')) or die $!;
    print $fh qq{do "\$::opt_libdir/AlsoAbsent.plib";\n1;\n};
    close($fh);

    my ($missing, $reached) = closure($tmp, 'fake.pl');
    is_deeply([sort keys %$missing], ['Absent.plib', 'AlsoAbsent.plib'],
        'reports a missing `do` target and one reached only transitively');
    is($missing->{'AlsoAbsent.plib'}, 'Present.pm',
        'names the referrer, so a gap points at the file that loads it');
    is_deeply($reached, ['Absent.plib', 'AlsoAbsent.plib', 'Present.pm'],
        'walks past the entrypoint into what the libraries themselves load');
}

# --- the real tree -----------------------------------------------------------
{
    my $dir = dirname($0);
    my ($missing, $reached) = closure($dir, 'hlstats.pl');

    cmp_ok(scalar @$reached, '>=', 9,
        'the entrypoint reaches at least the nine documented runtime files');
    ok(scalar(grep { $_ eq 'ConfigReaderSimple.pm' } @$reached),
        'the parser finds the first `require`, which is where a bare checkout died');
    ok(scalar(grep { $_ eq 'HLstats_GameConstants.plib' } @$reached),
        'the parser finds a `do` target reached only from a library');

    is_deeply($missing, {},
        'every file hlstats.pl loads through $opt_libdir is committed')
        or diag("missing: " . join(", ",
            map { "$_ (loaded by $missing->{$_})" } sort keys %$missing));
}

done_testing();
