#!/usr/bin/perl

use warnings;
use strict;

#========================================================================#

=pod

=head1 NAME

restartable-sim - start, and restart nSim as required.

=head1 OPTIONS

B<restartable-sim> [-h|--help] [--port=<port>]

=head1 SYNOPSIS

A full description for restartable-sim has not yet been written.

=over 2

=item I<--port>=<port>

The port to listen on, will default to 7890 if not specified.

=back

=cut

#========================================================================#

use lib "$ENV{HOME}/lib";
use Boolean;
use GiveHelp qw/usage/;         # Allow -h or --help command line options.
use IO::Socket;
use IO::Select;
use Getopt::Long;
use POSIX qw(:sys_wait_h);
use POSIX qw(:signal_h);

#========================================================================#

my $DEFAULT_PORT = 7890;
my $DEFAULT_IP = "localhost";
my $NSIM_IP = "192.168.218.2";
my $NSIM = undef;
my $MAX_RESTART_ITERATIONS = 120;

#========================================================================#

sub REAPER
{
  my $kid;
  do
  {
    $kid = waitpid(-1, WNOHANG);
  }
  while ($kid > 0);
}

sub SIGINT_HANDLER
{
  print "[$$] Got SIGINT\n";

  # This will only ever be defined in the nSIM monitor process.
  if ($NSIM)
  {
    print "[$$] Killing nsim\n";
    kill_nsim ($NSIM);
  }

  exit (0);
}

$SIG{CHLD} = \&REAPER;
$SIG{INT} = \&SIGINT_HANDLER;

#========================================================================#

exit (main ());

#========================================================================#

=pod

=head1 METHODS

The following methods are defined in this script.

=over 4

=cut

#========================================================================#

=pod

=item B<check_and_restart_nsim>

Currently undocumented.

=cut

sub check_and_restart_nsim {
  my $status;

  if (not ping_nsim ())
  {
    # Ooops, nSIM has stopped responding.
    print "[$$] nSIM is not responding to ping, restarting...\n";

    # Kill the old child if there is one.
    kill_nsim ($NSIM);

    # Block SIGINT while starting up the simulator.  This is an attempt to
    # ensure that on receiving SIGINT, variable NSIM will have been updated
    # correctly, and the simulator process will have started, and switched
    # to another process group.
    my $sigset = POSIX::SigSet->new(SIGINT);
    my $old_sigset = POSIX::SigSet->new ();
    print "[$$] Blocking SIGINT.\n";
    sigprocmask(SIG_BLOCK, $sigset, $old_sigset)
      or die "Could not block SIGINT: $!";

    # Create a new child to run nSIM.
    $NSIM = start_nsim ($old_sigset);

    # Now, we can unblock SIGINT.  The simulator process group might now
    # have unblocked SIGINT yet, but that's ok, it will soon once it's
    # switched to a new process group.  Any SIGINT we send it will just
    # wait until it unblocks.
    print "[$$] Unblocking SIGINT.\n";
    sigprocmask (SIG_SETMASK, $old_sigset)
      or die "Could not unblock SIGINT: $!";

    # Wait for the simulator to start up, ping at regular intervals until
    # we get a reply.
    $status = False;
    for (my $i = 0;
         (($i < $MAX_RESTART_ITERATIONS) and (not $status));
         $i++)
    {
      sleep (1);
      $status = ping_nsim ();
    }

    if ($status)
    {
      print "[$$] ...and it's back again.\n";
      return True;
    }
    else
    {
      print "[$$] ...and it can't be recovered.  Giving up.\n";
      return False;
    }
  }

  # Initial ping was a success, nSIM looks fine.
  return True;
}

#========================================================================#

=pod

=item B<ping_nsim>

Send a single ping to an nSIM simulator (IP 192.168.218.2) return true if
the ping is a success, otherwise, return false.

The ping will timeout after a single second, this is fine if the simulator
is running on the local machine and is not over loaded.

=cut

sub ping_nsim {
  return system ("ping -c 1 -w 1 $NSIM_IP &>/dev/null") == 0;
}

#========================================================================#

=pod

=item B<start_nsim>

Currently undocumented.

=cut

sub start_nsim {
  my $old_sigset = shift;

  my $pid = fork ();

  (defined $pid) or
    die "Failed to fork: $!";

  if ($pid == 0)
  {
    # Child, this becomes the new nSIM.
    setpgrp or
      die "Failed to set process group: $!";

    # The parent blocked SIGINT, we restore the signal mask to its previous
    # state now.
    print "[$$] Unblocking SIGINT.\n";
    sigprocmask (SIG_SETMASK, $old_sigset)
      or die "Could not unblock SIGINT: $!";

    print "[$$] About to exec nSIM.\n";
    exec "./start-sim.sh &>/dev/null" or
      die "Failed to exec: $!";
  }

  # Parent.
  print "[$$] Starting nSIM with pid = $pid\n";

  return $pid;
}

#========================================================================#

=pod

=item B<kill_nsim>

Currently undocumented.

=cut

sub kill_nsim {
  my $nsim = shift;

  return unless (defined $nsim);

  if (kill 0, $nsim)
  {
    kill '-INT', $nsim;

    if (kill 0, $nsim)
    {
      kill '-KILL', $nsim or
        die "Failed to send SIGKILL to simulator: $!";
    }
  }
}

#========================================================================#

=pod

=item B<main>

Currently undocumented.

=cut

sub main {
  my $server = $DEFAULT_IP;
  my $port = $DEFAULT_PORT;
  GetOptions ("port=i" => \$port);

  my ($write_fh, $read_fh) = start_nsim_monitor ();
  my $socket = initialise_server_socket ($server, $port);

  my $selector = IO::Select->new ($read_fh, $socket);
  my $restart_in_progress = False;
  my @clients;

  while (1)
  {
    my @ready = $selector->can_read (5);

    foreach my $fh (@ready)
    {
      if ($fh == $socket)
      {
        # Another client asking for a restart.
        my $new_socket = $fh->accept ()
          || die "Failed to create new socket after accept: $!";
        $new_socket->autoflush (1);
        push @clients, $new_socket;

        if (not $restart_in_progress)
        {
          # Trigger a new restart request.
          print $write_fh "RESTART?\n";
          $restart_in_progress = True;
        }
      }
      elsif ($fh == $read_fh)
      {
        # Status update from monitor.
        if (eof ($read_fh))
        {
          die "The nsim monitor process has died.\n";
        }

        my $status = <$read_fh>;
        chomp $status;

        if ($status eq "OK")
        {
          # The simulator has been restarted.
          print "[$$] The simulator should now be OK.\n";
        }
        elsif ($status eq "DEAD")
        {
          # The simulator could not be restarted.
          print "[$$] The simulator seems to be DEAD.\n";
        }
        else
        {
          die "Unknown status '$status'";
        }

        foreach my $c (@clients)
        {
          print $c $status."\n";
          close ($c);
        }

        @clients = ();

        $restart_in_progress = False;
      }
    }

    # Send WAIT to all active children.  If we end up spamming the children
    # with too many WAIT signals then we could gate this.  For now that seems
    # like over complexity.
    foreach my $c (@clients)
    {
      print $c "WAIT\n";
    }
  }

  return 0;
}

#========================================================================#

=pod

=item B<start_nsim_monitor>

Currently undocumented.

=cut

sub start_nsim_monitor {

  my ($read1, $write1, $read2, $write2);
  pipe ($read1, $write1) || die "Failed to create first pipe: $!";
  pipe ($read2, $write2) || die "Failed to create second pipe: $!";

  # Parent                Child
  # ======                =====
  #  write1 ----------------> read1
  #   read2 <---------------- write2

  my $pid = fork ();
  (defined $pid) or die "Failed to fork: $!";

  if ($pid)
  {
    # Parent.
    $write1->autoflush (1);
    $read2->autoflush (1);
    close ($read1);
    close ($write2);
    return ($write1, $read2);
  }

  # Child.
  print "[$$] Starting nSIM monitor.\n";
  $write2->autoflush (1);
  $read1->autoflush (1);
  close ($write1);
  close ($read2);

  if (not (check_and_restart_nsim ()))
  {
    print "[$$] Failed to start initial nSIM instance.\n";
    exit (1);
  }

  while (1)
  {
    print "[$$] nSIM monitor waiting for requests.\n";

    my $line = <$read1>;
    last unless (defined $line); # EOF.
    chomp ($line);

    ($line eq "RESTART?") || die "Unknown request '$line'";

    print "[$$] nSIM monitor received a 'RESTART?' request\n";
    if (not (check_and_restart_nsim ()))
    {
      print $write2 "DEAD\n";
      kill_nsim ();
      exit (1);
    }

    print "[$$] nSIM monitor sending OK response.\n";
    print $write2 "OK\n";
  }

  exit (0);
}

#========================================================================#

=pod

=item B<handle_restart_request>

Many processes will end up in here at the same time.  Each process
corresponds to a client that has discovered the simulator has died and
wants it to restart.

We need to seriealise the clients so that we only perform a single restart.

We also need to send a keep alive pulse to the client while the simulator
is restarting.

=cut

sub handle_restart_request {
  my $socket = shift;

  for (my $i = 0; $i < 5; $i++)
  {
    print $socket "WAIT\n";
    sleep 1;
  }

  print $socket "OK\n";
}

#========================================================================#

=pod

=item B<initialise_server_socket>

Currently undocumented.

=cut

sub initialise_server_socket {
  my $ip = shift;
  my $port = shift;

  my $socket = IO::Socket::INET->new (
    LocalHost => $ip,
    LocalPort => $port,
    Proto => 'tcp',
    Listen => 10,
    Reuse => 1);

  print "[$$] SERVER started on port $port\n";

  return $socket;
}

#========================================================================#

#========================================================================#

=pod

=back

=head1 AUTHOR

Andrew Burgess, 23 Jan 2015

=cut
