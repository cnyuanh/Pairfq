#!/usr/bin/env perl

=head1 NAME 
                                                                       
pairfq.pl - Sync paired-end sequences from separate FastA/Q files

=head1 SYNOPSIS    
 
pairfq.pl -t makpairs -f s_1_1_trim.fq -r s_1_2_trim.fq -fp s_1_1_trim_paired.fq -rp s_1_2_trim_paired.fq -fs s_1_1_trim_unpaired.fq -rs s_1_2_trim_unpaired.fq -im

=head1 DESCRIPTION
     
Re-pair paired-end sequences that may have been separated by quality trimming.
This script also writes the unpaired forward and reverse sequences to separate 
files so that they may be used for assembly or mapping. The input may be FastA
or FastQ format in either Illumina 1.3+ or Illumina 1.8 format. The input files
may be compressed with gzip or bzip2.

=head1 DEPENDENCIES

Only core Perl is required, no external dependencies. See below for information
on which Perls have been tested.

=head1 LICENSE
 
The MIT License should included with the project. If not, it can be found at: http://opensource.org/licenses/mit-license.php

Copyright (C) 2013 S. Evan Staton
 
=head1 TESTED WITH:

=over

=item *
Perl 5.14.1 (Red Hat Enterprise Linux Server release 5.7 (Tikanga))

=item *
Perl 5.14.2 (Red Hat Enterprise Linux Desktop release 6.2 (Santiago); Fedora 17)

=item *
Perl 5.18.0 (Red Hat Enterprise Linux Server release 5.9 (Tikanga))

=back

=head1 AUTHOR 

S. Evan Staton                                                

=head1 CONTACT
 
statonse at gmail dot com

=head1 REQUIRED ARGUMENTS

=over 2

=item -t, --task

The task to perform. Must be one of: 'addinfo', 'makepairs', 'joinpairs', or 'splitpairs'.

  addinfo    | Add the pair info back to the FastA/Q header.
  makepairs  | Pair the forward and reverse reads and write singletons for both forward and reverse reads to separate files.
  joinpairs  | Interleave the paired forward and reverse files.
  splitpairs | Split the interleaved file into separate files for the forward and reverse reads.

=back

=head1 OPTIONS

=over 2

=item -f, --forward

  The file of forward sequences from an Illumina paired-end sequencing run.

=item -r, --reverse

  The file of reverse sequences from an Illumina paired-end sequencing run.

=item -fp, --forw_paired

  The output file to place the paired forward reads.

=item -rp, --rev_paired

  The output file to place the paired reverse reads. 

=item -fs, --forw_unpaired

  The output file to place the unpaired forward reads. 

=item -rs, --rev_unpaired

  The output file to place the unpaired reverse reads. 

=item -im, --in_memory

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
use Encode qw(encode decode);
use File::Basename;
use Getopt::Long;
use DB_File;
use DBM_Filter;
use IO::Compress::Gzip qw(gzip $GzipError);
use IO::Compress::Bzip2 qw(bzip2 $Bzip2Error);
use Pod::Usage;

my ($task, $infile, $outfile, $fread, $rread, $fpread, $rpread, $fsread, $rsread, $pairnum, $memory, $compress, $help, $man);

GetOptions(
	   't|task=s'           => \$task,
	   'i|infile=s'         => \$infile,
	   'o|outfile=s'        => \$outfile,
	   'p|pairnum=i'        => \$pairnum, 
           'f|forward=s'        => \$fread,
           'r|reverse=s'        => \$rread,
           'fp|forw_paired=s'   => \$fpread,
           'rp|rev_paired=s'    => \$rpread,
           'fs|forw_unpaired=s' => \$fsread,
           'rs|rev_unpaired=s'  => \$rsread,
           'im|in_memory'       => \$memory,
           'c|compress=s'       => \$compress,
           'h|help'             => \$help,
           'm|man'              => \$man,
          ) || pod2usage( "Try '$0 --man' for more information." );

#
# Check @ARGV
#
usage() and exit(0) if $help;

pod2usage( -verbose => 2 ) if $man;

if (!$task) {
    say "\nERROR: Command line not parsed correctly. Check input.\n";
    usage();
    exit(1);
}

if ($compress) {
    unless ($compress eq 'gzip' || $compress eq 'bzip2') {
	say "\nERROR: '$compress' is not recognized as an argument to the --compress option. Must be 'gzip' or 'bzip2'. Exiting.\n";
	exit(1);
    }
}

if ($task eq 'addinfo') {
    if (!$pairnum || !$infile || !$outfile) {
	say "\nERROR: Command line not parsed correctly. Check input.\n";
	addinfo_usage();
	exit(1);
    }
    add_pair_info($pairnum, $infile, $outfile, $compress);
}
elsif ($task eq 'makepairs') {
    if (!$fread || !$rread || !$fpread || !$rpread || !$fsread || !$rsread) {
	say "\nERROR: Command line not parsed correctly. Check input.\n";
	makepairs_usage();
	exit(1);
    }
    make_pairs_and_singles($fread, $rread, $fpread, $rpread, $fsread, $rsread, $memory, $compress);
}
elsif ($task eq 'joinpairs') {
    if (!$fread || !$rread || !$outfile) {
	say "\nERROR: Command line not parsed correctly. Check input.\n";
	joinpairs_usage();
	exit(1);
    }
    pairs_to_interleaved($fread, $rread, $outfile, $memory, $compress);
}
elsif ($task eq 'splitpairs') {
    if (!$infile || !$fread || !$rread) {
	say "\nERROR: Command line not parsed correctly. Check input.\n";
	splitpairs_usage();
	exit(1);
    }
    interleaved_to_pairs($infile, $fread, $rread, $compress);

}
else {
    say "\nERROR: '$task' is not recognized. See the manual by typing 'perl pairfq -m', or see https://github.com/sestaton/Pairfq.\n";
    exit(1);
}

exit;
#
# Subs
#
sub add_pair_info {
    my ($pairnum, $infile, $outfile, $compress) = @_;
    my $pair;
    if ($pairnum == 1) {
	$pair = "/1";
    }
    elsif ($pairnum == 2) {
	$pair = "/2";
    }
    else {
	say "\nERROR: $pairnum is not correct. Must be 1 or 2. Exiting.";
	exit(1);
    }

    my $fh = get_fh($infile);
    open my $out, '>', $outfile or die "\nERROR: Could not open file: $!\n";

    my @aux = undef;
    my ($name, $comm, $seq, $qual);

    while (($name, $comm, $seq, $qual) = readfq(\*$fh, \@aux)) {
	if (defined $qual) {
	    say $out join "\n", "@".$name.$pair, $seq, '+', $qual;
	}
	else {
	    say $out join "\n", ">".$name.$pair, $seq;
	}
    }
    close $fh;
    close $out;

    compress($outfile) if $compress;
}

sub make_pairs_and_singles {
    my ($fread, $rread, $fpread, $rpread, $fsread, $rsread, $memory, $compress) = @_;

    my ($rseqpairs, $db_file, $rct) = store_pair($rread);

    my @faux = undef;
    my ($fname, $fcomm, $fseq, $fqual, $forw_id, $rev_id, $fname_enc);
    my ($fct, $fpct, $rpct, $pct, $fsct, $rsct, $sct) = (0, 0, 0, 0, 0, 0, 0);

    my $fh = get_fh($fread);
    open my $fp, '>', $fpread or die "\nERROR: Could not open file: $fpread\n";
    open my $rp, '>', $rpread or die "\nERROR: Could not open file: $rpread\n";
    open my $fs, '>', $fsread or die "\nERROR: Could not open file: $fsread\n";

    binmode $fp, ":utf8";
    binmode $rp, ":utf8";
    binmode $fs, ":utf8";

    while (($fname, $fcomm, $fseq, $fqual) = readfq(\*$fh, \@faux)) {
	$fct++;
	if ($fname =~ /(\/\d)$/) {
	    $fname =~ s/$1//;
	}
	elsif (defined $fcomm && $fcomm =~ /^\d/) {
	    $fcomm =~ s/^\d//;
	    $fname = mk_key($fname, $fcomm);
	}
	else {
        say "\nERROR: Could not determine FastA/Q format. ".
            "Please see https://github.com/sestaton/Pairfq or the README for supported formats. Exiting.\n";
        exit(1);
    }
    
	if ($fname =~ /\N{INVISIBLE SEPARATOR}/) {
	    my ($name, $comm);
	    ($name, $comm) = mk_vec($fname);
	    $forw_id = $name.q{ 1}.$comm;
	    $rev_id  = $name.q{ 2}.$comm;
	}

	$fname_enc = encode('UTF-8', $fname);
	if (exists $rseqpairs->{$fname_enc}) {
	    $fpct++; $rpct++;
	    if (defined $fqual) {
		my ($rread, $rqual) = mk_vec($rseqpairs->{$fname_enc});
		if ($fname =~ /\N{INVISIBLE SEPARATOR}/) {
		    say $fp join "\n","@".$forw_id, $fseq, "+", $fqual;
		    say $rp join "\n","@".$rev_id, $rread, "+", $rqual;
		} 
		else {
		    say $fp join "\n","@".$fname.q{/1}, $fseq, "+", $fqual;
		    say $rp join "\n","@".$fname.q{/2}, $rread, "+", $rqual;
		}
	    } 
	    else {
		if ($fname =~ /\N{INVISIBLE SEPARATOR}/) {
		    say $fp join "\n",">".$forw_id, $fseq;
		    say $rp join "\n",">".$rev_id, $rseqpairs->{$fname_enc};
		} 
		else {
		    say $fp join "\n",">".$fname.q{/1}, $fseq;
		    say $rp join "\n",">".$fname.q{/2}, $rseqpairs->{$fname_enc};
		}
	    }
	    delete $rseqpairs->{$fname_enc};
	} 
	else {
	    $fsct++;
	    if (defined $fqual) {
		if ($fname =~ /\N{INVISIBLE SEPARATOR}/) {
		    say $fs join "\n","@".$forw_id, $fseq, "+", $fqual;
		} 
		else {
		    say $fs join "\n","@".$fname.q{/1}, $fseq, "+", $fqual;
		}
	    } 
	    else {
		if ($fname =~ /\N{INVISIBLE SEPARATOR}/) {
		    say $fs join "\n",">".$forw_id, $fseq;
		} 
		else {
		    say $fs join "\n",">".$fname.q{/1}, $fseq;
		}
	    }
	}
	$forw_id = undef;
	$rev_id = undef;
    }
    close $fh;
    close $fp;
    close $rp;
    close $fs;

    open my $rs, '>', $rsread or die "\nERROR: Could not open file: $rsread\n";
    binmode $rs, ":utf8";

    while (my ($rname_up, $rseq_up) = each %$rseqpairs) {
	$rsct++;
	my $rname_unenc = decode('UTF-8', $rname_up);
	my ($name_up_unenc, $comm_up_unenc) = mk_vec($rname_unenc);
	my ($seq_up_unenc, $qual_up_unenc) = mk_vec($rseq_up);

	my $rev_id_up .= $name_up_unenc.q{ 2}.$comm_up_unenc if defined $comm_up_unenc;
    
	if (defined $comm_up_unenc && defined $qual_up_unenc) {
	    say $rs join "\n","@".$rev_id_up, $seq_up_unenc, "+", $qual_up_unenc;
	} 
	elsif (defined $comm_up_unenc && !defined $qual_up_unenc) {
	    say $rs join "\n",">".$rev_id_up, $rseq_up;
	} 
	elsif (!defined $comm_up_unenc && defined $qual_up_unenc) {
	    say $rs join "\n", "@".$name_up_unenc.q{/2}, $seq_up_unenc, "+", $qual_up_unenc;
	}
	else {
	    say $rs join "\n",">".$name_up_unenc.q{/2}, $rseq_up;
	}
    }
    close $rs;

    compress($fpread, $rpread, $fsread, $rsread) if $compress;
    $pct = $fpct + $rpct;
    $sct = $fsct + $rsct;
    untie %$rseqpairs if defined $memory;
    unlink $db_file if -e $db_file;

    say "Total forward reads in $fread:              $fct";
    say "Total reverse reads in $rread:              $rct";
    say "Total forward paired reads in $fpread:      $fpct";
    say "Total reverse paired reads in $rpread:      $rpct";
    say "Total forward unpaired reads in $fsread:    $fsct";
    say "Total reverse unpaired reads in $rsread:    $rsct\n";
    say "Total paired reads in $fpread and $rpread:  $pct";
    say "Total upaired reads in $fsread and $rsread: $sct";

}

sub pairs_to_interleaved {
    my ($forward, $reverse, $outfile, $memory, $compress) = @_;

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
}

sub interleaved_to_pairs {
    my ($infile, $forward, $reverse, $compress) = @_;
    my $fh = get_fh($infile);
    open my $f, '>', $forward or die "\nERROR: Could not open file: $!\n";
    open my $r, '>', $reverse or die "\nERROR: Could not open file: $!\n"; 

    my @aux = undef;
    my ($name, $comm, $seq, $qual);

    while (($name, $comm, $seq, $qual) = readfq(\*$fh, \@aux)) {
	if (defined $comm && $comm =~ /^1/ || $name =~ /1$/) {
	    say $f join "\n", ">".$name, $seq if !defined $qual && !defined $comm;
	    say $f join "\n", ">".$name.q{ }.$comm, $seq, if !defined $qual && defined $comm;
	    say $f join "\n", "@".$name, $seq, '+', $qual if defined $qual && !defined $comm;
	    say $f join "\n", "@".$name.q{ }.$comm, $seq, '+', $qual if defined $qual && defined $comm;
	}
	elsif (defined $comm && $comm =~ /^2/ || $name =~ /2$/) {
	    say $r join "\n", ">".$name, $seq if !defined $qual && !defined $comm;
	    say $r join "\n", ">".$name.q{ }.$comm, $seq if !defined $qual && defined $comm;
	    say $r join "\n", "@".$name, $seq, "+", $qual if defined $qual && !defined $comm;
	    say $r join "\n", "@".$name.q{ }.$comm, $seq, "+", $qual if defined $qual && defined $comm;
	}
    }

    close $fh;
    close $f;
    close $r;

    compress($forward, $reverse) if $compress;
}

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
    my ($fp, $rp, $fs, $rs) = @_;
    if ($compress eq 'gzip') {
	my $fpo = $fp.".gz";
	my $rpo = $rp.".gz" if defined $rp;
	my $fso = $fs.".gz" if defined $fs;
	my $rso = $rs.".gz" if defined $rs;
	
	gzip $fp => $fpo or die "gzip failed: $GzipError\n";
	gzip $rp => $rpo or die "gzip failed: $GzipError\n" if defined $rp;
	gzip $fs => $fso or die "gzip failed: $GzipError\n" if defined $fs;
        gzip $rs => $rso or die "gzip failed: $GzipError\n" if defined $rs;

	unlink $fp;
	unlink $rp if defined $rp;
	unlink $fs if defined $fs;
	unlink $rs if defined $rs;
    }
    elsif ($compress eq 'bzip2') {
	my $fpo = $fp.".bz2";
	my $rpo = $rp.".bz2" if defined $rp;
	my $fso = $fs.".bz2" if defined $fs;
	my $rso = $rs.".bz2" if defined $rs;

	bzip2 $fp => $fpo or die "bzip2 failed: $Bzip2Error\n";
	bzip2 $rp => $rpo or die "bzip2 failed: $Bzip2Error\n" if defined $rp;
	bzip2 $fs => $fso or die "bzip2 failed: $Bzip2Error\n" if defined $fs;
	bzip2 $rs => $rso or die "bzip2 failed: $Bzip2Error\n" if defined $rs;

	unlink $fp; 
	unlink $rp if defined $rp;
	unlink $fs if defined $fs;
	unlink $rs if defined $rs;
    }
}

sub store_pair {
    my ($file, $memory) = @_;

    my $rct = 0;
    my %rseqpairs;
    $DB_BTREE->{cachesize} = 100000;
    $DB_BTREE->{flags} = R_DUP;
    my $db_file = "pairfq.bdb";
    unlink $db_file if -e $db_file;

    unless (defined $memory) { 
	my $db = tie %rseqpairs, 'DB_File', $db_file, O_RDWR|O_CREAT, 0666, $DB_BTREE
	    or die "\nERROR: Could not open DBM file $db_file: $!\n";
	$db->Filter_Value_Push("utf8");
    }

    my @raux = undef;
    my ($rname, $rcomm, $rseq, $rqual, $rname_k, $rname_enc);

    my $fh = get_fh($file);

    {
	local @SIG{qw(INT TERM HUP)} = sub { if (defined $memory && -e $db_file) { untie %rseqpairs; unlink $db_file if -e $db_file; } };

	while (($rname, $rcomm, $rseq, $rqual) = readfq(\*$fh, \@raux)) {
	    $rct++;
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

	    $rname = encode('UTF-8', $rname);
	    $rseqpairs{$rname} = mk_key($rseq, $rqual) if defined $rqual;
	    $rseqpairs{$rname} = $rseq if !defined $rqual;
	}
	close $fh;
    }
    return (\%rseqpairs, $db_file, $rct);
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
USAGE: $script [-t] [-h] [-m]

Required:
    -t|task           :       The task to perform. May be one of: 'addinfo', 'makepairs', 'joinpairs', or 'splitpairs'.
                              Type the name of the task with no arguments to see the specific usage of that command.

Options:
    -h|help           :       Print a usage statement.
    -m|man            :       Print the full documentation.

EOF
}

sub makepairs_usage {
    my $script = basename($0);
    print STDERR<<EOF
USAGE: $script [-f] [-r] [-fp] [-rp] [-fs] [-rs] [-im] [-h] [-im]

Required:
    -f|forward        :       File of foward reads (usually with "/1" or " 1" in the header).
    -r|reverse        :       File of reverse reads (usually with "/2" or " 2" in the header).
    -fp|forw_paired   :       Name for the file of paired forward reads.
    -rp|rev_paired    :       Name for the file of paired reverse reads.
    -fs|forw_unpaired :       Name for the file of singleton forward reads.
    -rs|rev_unpaired  :       Name for the file of singleton reverse reads.

Options:
    -im|in_memory     :       Construct a database in memory for faster execution.
                              NB: This may result in large RAM usage for a large number of sequences. 
    -c|compress       :       Compress the output files. Options are 'gzip' or 'bzip2' (Default: No).
    -h|help           :       Print a usage statement.
    -m|man            :       Print the full documentation.

EOF
}

sub addinfo_usage {
    my $script = basename($0);
    print STDERR<<EOF
USAGE: $script [-i] [-o] [-p] [-h] [-m]

Required:
    -i|infile        :       The file of sequences without the pair information in the sequence name.
    -o|outfile       :       The file of sequences that will contain the sequence names with the pair information.
    -p|pairnum       :       The number to append to the sequence name. Integer (Must be 1 or 2).

Options:
    -c|compress      :       Compress the output files. Options are 'gzip' or 'bzip2' (Default: No).
    -h|help          :       Print a usage statement.
    -m|man           :       Print the full documentation.

EOF
}

sub splitpairs_usage {
    my $script = basename($0);
    print STDERR<<EOF
USAGE: $script [-i] [-f] [-r] [-c] [-h] [-m]

Required:
    -i|infile         :       File of interleaved forward and reverse reads.
    -f|forward        :       File to place the foward reads.
    -r|reverse        :       File to place the reverse reads.

Options:
    -c|compress       :       Compress the output files. Options are 'gzip' or 'bzip2' (Default: No).
    -h|help           :       Print a usage statement.
    -m|man            :       Print the full documentation.

EOF
}

sub joinpairs_usage {
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
