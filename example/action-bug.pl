#!/usr/bin/env perl
use strict; use warnings;

while (my $l = <DATA>) {
    chomp $l;
    print "$l\n";
}

__DATA__
123456789012 This is a test
3456789012345This is another test
6789012345678This is yet another test
9012345678901Is this yet another test?
234567890123 Yes, this is another test.
4567890123456I think this is a test.
7890123456789Now is the time.
0123456789012For all good men.
3456789012345To come to the aid party.
678901234678 This is the tenth line.
