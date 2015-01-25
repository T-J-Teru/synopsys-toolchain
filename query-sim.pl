#!/usr/bin/perl

use warnings;
use strict;

#========================================================================#

=pod

=head1 NAME

query-sim - a quick summary of what query-sim does.

=head1 OPTIONS

B<query-sim> [-h|--help]

=head1 SYNOPSIS

A full description for query-sim has not yet been written.

=cut

#========================================================================#

use lib "$ENV{HOME}/lib";
use GiveHelp qw/usage/;         # Allow -h or --help command line options.
use Socket;

# initialize host and port
my $host = shift || 'localhost';
my $port = shift || 7890;

my $server = $host;  # Host IP running the server

# create the socket, connect to the port
socket (my $socket, PF_INET, SOCK_STREAM, (getprotobyname ('tcp')) [2])
  or die "Can't create a socket $!\n";
connect ($socket, pack_sockaddr_in ($port, inet_aton ($server)))
  or die "Can't connect to port $port! \n";

my $line;
while ($line = <$socket>) {
  chomp $line;
  print "$line\n";
}
close $socket or die "close: $!";

#========================================================================#

=pod

=head1 METHODS

The following methods are defined in this script.

=over 4

=cut

#========================================================================#

#========================================================================#

=pod

=back

=head1 AUTHOR

Andrew Burgess, 23 Jan 2015

=cut
