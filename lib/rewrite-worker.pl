#!/usr/bin/env perl
use strict;
use warnings;
use bytes;
use Digest::SHA qw(sha1_hex sha256_hex);
use File::Spec;

binmode STDIN;
binmode STDOUT;
$| = 1;

my $mode = shift @ARGV // '';
if ($mode eq 'scan-signatures') {
    while (my $header = <STDIN>) {
        $header =~ s/\n\z//;
        my ($oid, $type, $size) = split / /, $header;
        defined($size) && $type eq 'commit' && $size =~ /\A[0-9]+\z/ or die "invalid cat-file batch record\n";
        my $raw = '';
        while (length($raw) < $size) {
            my $read = read STDIN, my $chunk, $size - length($raw);
            defined($read) && $read > 0 or die "short cat-file batch record\n";
            $raw .= $chunk;
        }
        read STDIN, my $delimiter, 1;
        $delimiter eq "\n" or die "invalid cat-file batch delimiter\n";
        my $lf = index($raw, "\n\n");
        my $crlf = index($raw, "\r\n\r\n");
        my $header_end = $crlf >= 0 && ($lf < 0 || $crlf <= $lf) ? $crlf : $lf;
        $header_end >= 0 or die "commit object has no header separator\n";
        my $commit_header = substr($raw, 0, $header_end);
        print "$oid\n" if $commit_header =~ /(?:\A|\n)gpgsig /;
    }
    exit 0;
}

if ($mode eq 'extract') {
    my $directory = shift @ARGV or die "missing extraction directory\n";
    while (my $header = <STDIN>) {
        $header =~ s/\n\z//;
        my ($oid, $type, $size) = split / /, $header;
        defined($size) && $type eq 'commit' && $size =~ /\A[0-9]+\z/ or die "invalid cat-file batch record\n";
        my $raw = '';
        while (length($raw) < $size) {
            my $read = read STDIN, my $chunk, $size - length($raw);
            defined($read) && $read > 0 or die "short cat-file batch record\n";
            $raw .= $chunk;
        }
        read STDIN, my $delimiter, 1;
        $delimiter eq "\n" or die "invalid cat-file batch delimiter\n";
        open my $output, '>:raw', File::Spec->catfile($directory, $oid) or die "cannot create extracted object: $!\n";
        print {$output} $raw or die "cannot write extracted object: $!\n";
        close $output or die "cannot close extracted object: $!\n";
    }
    exit 0;
}

if ($mode ne 'rewrite') {
    die "usage: rewrite-worker.pl scan-signatures | extract DIRECTORY | rewrite RAW-DIRECTORY OUTPUT-DIRECTORY sha1|sha256\n";
}

my ($raw_directory, $output_directory, $format) = @ARGV;
defined($format) && ($format eq 'sha1' || $format eq 'sha256') or die "invalid object format\n";

while (my $instruction = <STDIN>) {
    $instruction =~ s/\n\z//;
    my ($old_oid, $author_epoch, $author_zone, $committer_epoch, $committer_zone, $parent_text) = split /\t/, $instruction, 6;
    my %parent_map;
    for my $pair (split /,/, ($parent_text // '')) {
        next if $pair eq '';
        my ($old, $new) = split /=/, $pair, 2;
        defined($new) or die "invalid parent mapping\n";
        $parent_map{$old} = $new;
    }

    open my $input, '<:raw', File::Spec->catfile($raw_directory, $old_oid) or die "cannot read extracted object: $!\n";
    local $/;
    my $raw = <$input>;
    close $input;
    defined($raw) or die "empty extracted object\n";

    my $lf = index($raw, "\n\n");
    my $crlf = index($raw, "\r\n\r\n");
    my $header_end;
    if ($crlf >= 0 && ($lf < 0 || $crlf <= $lf)) { $header_end = $crlf; }
    elsif ($lf >= 0) { $header_end = $lf; }
    else { die "commit object has no header separator\n"; }
    my $header = substr($raw, 0, $header_end);
    my $tail = substr($raw, $header_end);
    my @lines = split /(?<=\n)/, $header, -1;
    for my $line (@lines) {
        if ($line =~ /\Aparent ([0-9a-f]+)(\r?\n)?\z/) {
            my ($old, $ending) = ($1, defined($2) ? $2 : '');
            $line = 'parent ' . ($parent_map{$old} // $old) . $ending;
        } elsif ($author_epoch ne '-' && $line =~ /\Aauthor (.*) (-?[0-9]+) ([+-][0-9]{4})(\r?\n)?\z/s) {
            my ($identity, $ending) = ($1, defined($4) ? $4 : '');
            $line = "author $identity $author_epoch $author_zone$ending";
        } elsif ($committer_epoch ne '-' && $line =~ /\Acommitter (.*) (-?[0-9]+) ([+-][0-9]{4})(\r?\n)?\z/s) {
            my ($identity, $ending) = ($1, defined($4) ? $4 : '');
            $line = "committer $identity $committer_epoch $committer_zone$ending";
        }
    }
    my $changed = join('', @lines) . $tail;
    my $hash_input = 'commit ' . length($changed) . "\0" . $changed;
    my $new_oid = $format eq 'sha1' ? sha1_hex($hash_input) : sha256_hex($hash_input);
    my $path = File::Spec->catfile($output_directory, "$new_oid.commit");
    open my $output, '>:raw', $path or die "cannot create rewritten object: $!\n";
    print {$output} $changed or die "cannot write rewritten object: $!\n";
    close $output or die "cannot close rewritten object: $!\n";
    print "$new_oid\t$path\n";
}
