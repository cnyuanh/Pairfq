#!/usr/bin/env perl

=head1 NAME 
                                                                       
pairs_to_interleaved.pl - Create an interleaved FastA/Q file for assembly or mapping

=head1 SYNOPSIS    
 
pairs_to_interleaved.pl -f seq_1_p.fq -r seq_2_p.fq -o seqs_interl.fq

=head1 DESCRIPTION
     
For some assembly programs, such as Velvet, paired-end sequence files must be interleaved.
This program creates a single interleaved file from two paired files, which have been created
by pairfq.pl (or some other method). The input may be FastA or FastQ.

=head1 DEPENDENCIES

Only core Perl is required, no external dependencies. See below for information
on which Perls have been tested.

=head1 LICENSE
 
The MIT License should included with the project. If not, it can be found at: http://opensource.org/licenses/mit-license.php

Copyright (C) 2013 S. Evan Staton
 
=head1 TESTED WITH:

=over

=item *
Perl 5.18.0 (Red Hat Enterprise Linux Server release 5.9 (Tikanga))

=back

=head1 AUTHOR 

S. Evan Staton                                                

=head1 CONTACT
 
statonse at gmail dot com

=head1 REQUIRED ARGUMENTS

=over 2

=item -f, --forward

The file of paired forward sequences from an Illumina paired-end sequencing run.

=item -r, --reverse                                                                                                                                                       
The file of paired reverse sequences from an Illumina paired-end sequencing run.

=item -o, --outfile

The interleaved file to produce from the forward and reverse files.

=back

=head1 OPTIONS

=over 2

=item -im, --memory

The computation should be done in memory instead of on the disk. This will be faster, but may use a large amount
of RAM if there are many millions of sequences in each input file.

=item -c, --compress

The output files should be compressed. If given, this option must be given the arguments 'gzip' to compress with gzip,
or 'bzip2' to compress with bzip2.

=item -h, --help

Print a usage statement. 

=item -m, --man

Print the full documentation.

=cut

use 5.012;
use utf8;
use strict;
use warnings;
use warnings FATAL => "utf8";
use charnames qw(:full :short);
use Encode qw(encode);
use File::Basename;
use DB_File;
use DBM_Filter;
use Getopt::Long;
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Compress::Bzip2 qw(bzip2 $Bzip2Error);
use Pod::Usage;

my $forward;
my $reverse;
my $outfile;
my $memory;
my $compress;
my $help;
my $man;

GetOptions(
	   'f|forward=s'   => \$forward,
	   'r|reverse=s'   => \$reverse,
	   'o|outfile=s'   => \$outfile,
	   'im|memory'     => \$memory,
	   'c|compress=s'  => \$compress,
	   'h|help'        => \$help,
	   'm|man'         => \$man,
	   ) || pod2usage( "Try '$0 --man' for more information." );;

#
# Check @ARGV
#
usage() and exit(0) if $help;

pod2usage( -verbose => 2 ) if $man;

if (!$forward || !$reverse || !$outfile) {
    say "\nERROR: Command line not parsed correctly. Check input.\n";
    usage();
    exit(1);
}

if ($compress) {
    unless ($compress =~ /gzip/i || $compress =~ /bzip2/i) {
        say "\nERROR: $compress is not recognized as an argument to the --compress option. Must be 'gzip' or 'bzip2'. Exiting";
        exit(1);
    }
}

my ($pairs, $db_file, $ct) = store_pair($forward);
my $fh = get_fh($reverse);
open my $out, '>', $outfile or die "\nERROR: Could not open file: $!\n";
binmode $out, ":utf8";

my @raux = undef;
my ($rname, $rcomm, $rseq, $rqual, $forw_id, $rev_id, $rname_enc);

while (($rname, $rcomm, $rseq, $rqual) = readfq(\*$fh, \@raux)) {
    if ($rname =~ /(\/\d)$/) {
	$rname =~ s/$1//;
    }
    elsif (defined $rcomm && $rcomm =~ /^\d/) {
	$rcomm =~ s/^\d//;
	$rname = mk_key($rname, $rcomm);
    }
    else {
        say "\nERROR: Could not determine FastA/Q format. ".
            "Please see https://github.com/sestaton/Pairfq or the README for supported formats. Exiting.\n";
        exit(1);
    }

    if ($rname =~ /\N{INVISIBLE SEPARATOR}/) {
        my ($name, $comm) = mk_vec($rname);
        $forw_id = $name.q{ 1}.$comm;
        $rev_id  = $name.q{ 2}.$comm;
    }

    $rname_enc = encode('UTF-8', $rname);
    if (exists $pairs->{$rname_enc}) {
	if (defined $rqual) {
	    my ($seqf, $qualf) = mk_vec($pairs->{$rname_enc});
	    if ($rname =~ /\N{INVISIBLE SEPARATOR}/) {
		say $out join "\n", "@".$forw_id, $seqf, "+", $qualf;
		say $out join "\n", "@".$rev_id, $rseq, "+", $rqual;
	    }
	    else {
		say $out join "\n", "@".$rname.q{/1}, $seqf, "+", $qualf;
                say $out join "\n", "@".$rname.q{/2}, $rseq, "+", $rqual;
	    }
	}
	else {
	    if ($rname =~ /\N{INVISIBLE SEPARATOR}/) {
		say $out join "\n", ">".$forw_id, $pairs->{$rname_enc};
		say $out join "\n", ">".$rev_id, $rseq;
	    }
	    else {
		say $out join "\n", ">".$rname.q{/1}, $pairs->{$rname_enc};
		say $out join "\n", ">".$rname.q{/2}, $rseq;                                               
	    }
	}
    }
}
close $fh;
close $out;

untie %$pairs if defined $memory;
unlink $db_file if -e $db_file;

compress($outfile) if $compress;
exit;
#
# subroutines
#
sub get_fh {
    my ($file) = @_;

    my $fh;
    if ($file =~ /\.gz$/) {
        open $fh, '-|', 'zcat', $file or die "\nERROR: Could not open file: $file\n";
    }
    elsif ($file =~ /\.bz2$/) {
        open $fh, '-|', 'bzcat', $file or die "\nERROR: Could not open file: $file\n";
    }
    else {
        open $fh, '<', $file or die "\nERROR: Could not open file: $file\n";
    }

    return $fh;
}

sub compress {
    my ($outfile) = @_;
    if ($compress =~ /gzip/i) {
        my $outfilec = $outfile.".gz";
        gzip $outfile => $outfilec or die "gzip failed: $GzipError\n";
        unlink $outfile;
    }
    elsif ($compress =~ /bzip2/i) {
        my $outfilec = $outfile.".bz2";
        bzip2 $outfile => $outfilec or die "bzip2 failed: $Bzip2Error\n";
        unlink $outfile;
    }
}

sub store_pair {
    my ($file) = @_;

    my $ct = 0;
    my %seqpairs;
    $DB_BTREE->{cachesize} = 100000;
    $DB_BTREE->{flags} = R_DUP;
    my $db_file = "pairfq.bdb";
    unlink $db_file if -e $db_file;

    unless (defined $memory) { 
        my $db = tie %seqpairs, 'DB_File', $db_file, O_RDWR|O_CREAT, 0666, $DB_BTREE
            or die "\nERROR: Could not open DBM file $db_file: $!\n";
        $db->Filter_Value_Push("utf8");
    }

    my @aux = undef;
    my ($name, $comm, $seq, $qual);

    open my $f, '<', $file or die "\nERROR: Could not open file: $file\n";

    {
        local @SIG{qw(INT TERM HUP)} = sub { if (defined $memory && -e $db_file) { untie %seqpairs; unlink $db_file if -e $db_file; } };

        while (($name, $comm, $seq, $qual) = readfq(\*$f, \@aux)) {
            $ct++;
            if ($name =~ /(\/\d)$/) {
                $name =~ s/$1//;
            }
            elsif (defined $comm && $comm =~ /^\d/) {
                $comm =~ s/^\d//;
                $name = mk_key($name, $comm);
            }
            else {
                say "\nERROR: Could not determine FastA/Q format. ".
                    "Please see https://github.com/sestaton/Pairfq or the README for supported formats. Exiting.\n";
                exit(1);
            }

            $name = encode('UTF-8', $name);
            $seqpairs{$name} = mk_key($seq, $qual) if defined $qual;
            $seqpairs{$name} = $seq if !defined $qual;
        }
        close $f;
    }
    return (\%seqpairs, $db_file, $ct);
}

sub readfq {
    my ($fh, $aux) = @_;
    @$aux = [undef, 0] if (!@$aux);
    return if ($aux->[1]);
    if (!defined($aux->[0])) {
        while (<$fh>) {
            chomp;
            if (substr($_, 0, 1) eq '>' || substr($_, 0, 1) eq '@') {
                $aux->[0] = $_;
                last;
            }
        }
        if (!defined($aux->[0])) {
            $aux->[1] = 1;
            return;
        }
    }
    my ($name, $comm);
    defined $_ && do {
	($name, $comm) = /^.(\S+)(?:\s+)(\S+)/ ? ($1, $2) : 
                         /^.(\S+)/ ? ($1, '') : ('', '');
    };
    my $seq = '';
    my $c;
    $aux->[0] = undef;
    while (<$fh>) {
        chomp;
        $c = substr($_, 0, 1);
        last if ($c eq '>' || $c eq '@' || $c eq '+');
        $seq .= $_;
    }
    $aux->[0] = $_;
    $aux->[1] = 1 if (!defined($aux->[0]));
    return ($name, $comm, $seq) if ($c ne '+');
    my $qual = '';
    while (<$fh>) {
        chomp;
        $qual .= $_;
        if (length($qual) >= length($seq)) {
            $aux->[0] = undef;
            return ($name, $comm, $seq, $qual);
        }
    }
    $aux->[1] = 1;
    return ($name, $seq);
}

sub mk_key { join "\N{INVISIBLE SEPARATOR}", @_ }

sub mk_vec { split "\N{INVISIBLE SEPARATOR}", shift }

sub usage {
    my $script = basename($0);
    print STDERR<<EOF
USAGE: $script [-f] [-r] [-o] [-im] [-h] [-m]

Required:
    -f|forward        :       File of foward reads (usually with "/1" or " 1" in the header).
    -r|reverse        :       File of reverse reads (usually with "/2" or " 2" in the header).
    -o|outfile        :       File of interleaved reads.

Options:
    -im|in_memory     :       Construct a database in memory for faster execution.
                              NB: This may result in large RAM usage for a large number of sequences. 
    -c|compress       :       Compress the output files. Options are 'gzip' or 'bzip2' (Default: No).
    -h|help           :       Print a usage statement.
    -m|man            :       Print the full documentation.

EOF
}
