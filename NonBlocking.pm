package Net::Server::NonBlocking;

use 5.000503;

use strict;
use warnings;
use POSIX;
use IO::Socket;
use IO::Select;
use Socket;
use Fcntl;
use Tie::RefHash;
use vars qw($VERSION);
use Data::Dumper;

$VERSION = '0.01';

my @now=localtime(time);
my $cronCounter=$now[0]+60*$now[1]+3600*$now[2]+3600*24*$now[3];
my %buff;

# begin with empty buffers
my %inbuffer  = ();
my %outbuffer = ();
my %ready = ();

my %turn_timeout;
my %turn_timeout_trigger;
my $select;
my %idle;
my %timer;
my %map_all;
my %map_specific;
my %map_sock;

tie %ready, 'Tie::RefHash';

sub new{
	my($proto,@arg)=@_;
	my $class=ref($proto) || $proto;
	my $hash=$arg[0];

	my $self={};
	$self->{pidfile}=exists $hash->{pidfile} ? $hash->{pidfile} : '/tmp/anonymous_server';

	bless $self,$class;
}

sub add {
	my $self=shift;
	my $hash=shift;

	die("server_name is required") if not exists $hash->{server_name};
	die("local_port is required") if not exists $hash->{local_port};

	my $server = IO::Socket::INET->new(
			LocalAddr => exists $hash->{local_address} ? 
					$hash->{local_address} : 'localhost',
			LocalPort => $hash->{local_port},
			Listen    => 50,
			Proto	=> 'tcp',
			Reuse	=> 1)
	  or die "Can't make server socket -- $@\n";
	$self->nonblock($server);

	$self->{listen}->{$hash->{server_name}}->{socket}=$server;
	$self->{listen}->{$hash->{server_name}}->{local_address}=
			exists $hash->{local_address} ? $hash->{local_address} : 'localhost';
	$self->{listen}->{$hash->{server_name}}->{local_port}=$hash->{local_port};
	$self->{listen}->{$hash->{server_name}}->{delimiter}=
			exists $hash->{delimiter} ? $hash->{delimiter} : "\0";
	$self->{listen}->{$hash->{server_name}}->{string_format}=
			exists $hash->{string_format} ? $hash->{string_format} : '.*?';
	$self->{listen}->{$hash->{server_name}}->{timeout}=
			exists $hash->{timeout} ? $hash->{timeout} : 300;
	$self->{listen}->{$hash->{server_name}}->{on_connected}=
			exists $hash->{on_connected} ? $hash->{on_connected} : sub {};
	$self->{listen}->{$hash->{server_name}}->{on_disconnected}=
			exists $hash->{on_disconnected} ? $hash->{on_disconnected} : sub {};
	$self->{listen}->{$hash->{server_name}}->{on_recv_msg}=
			exists $hash->{on_recv_msg} ? $hash->{on_recv_msg} : sub {};

	if (exists $hash->{local_address}) {
		$map_specific{"$hash->{local_address}:$hash->{local_port}"}=
			$hash->{server_name};
	} else {
		$map_all{$hash->{local_port}}=
			$hash->{server_name};
	}

	$map_sock{$server} = $hash->{server_name};
}

sub nonblock {
	my $self=shift;
	my $socket=shift;
	my $flags;
	
	$flags = fcntl($socket, F_GETFL, 0)
		or die "Can't get flags for socket: $!\n";
	fcntl($socket, F_SETFL, $flags | O_NONBLOCK)
		or die "Can't make socket nonblocking: $!\n";
}

sub handle {
	my $self=shift;
	my $server_name=shift;
	my $client = shift;
	my $request;

	# requests are in $ready{$client}
	# send output to $outbuffer{$client}

	foreach $request (@{$ready{$client}}) {
        		# $request is the text of the request
        		# put text of reply into $outbuffer{$client}

		$self->{listen}->{$server_name}->{on_recv_msg}->($self,$client,$request);
	}

	delete $ready{$client};
}

sub get_server_name {
	my $self=shift;
	my $client=shift;
	my @caller=caller();

	return $map_sock{$client} if exists $map_sock{$client};

	if (exists $map_specific{$client->sockhost().":".$client->sockport()}) {
		return $map_specific{$client->sockhost().":".$client->sockport()};
	} else {
		return $map_all{$client->sockport()};
	}
}

sub start_turn {
	my $self=shift;
	my $client=shift;
	my $time=shift;

	$turn_timeout{$client}=$time;
	$turn_timeout_trigger{$client}=$_[0];
}

sub reset_turn {
	my $self=shift;
	my $client=shift;

	$turn_timeout{$client}=-1;
	delete($turn_timeout_trigger{$client});
}

sub close_client {
	my $self=shift;
	my $client=shift;

	#print "Idle delete close_client $client\n"; 

	delete $turn_timeout{$client};
	delete $turn_timeout_trigger{$client};
	delete $idle{$client};
	delete $inbuffer{$client};
	delete $outbuffer{$client};
	delete $ready{$client};

	$select->remove($client);
	close $client if $client;
}

sub erase_client {
	my $self=shift;
	my $server_name=shift;
	my $client=shift;

	delete $turn_timeout{$client};
	delete $turn_timeout_trigger{$client};
	delete $idle{$client};
	delete $inbuffer{$client};
	delete $outbuffer{$client};
	delete $ready{$client};

	$self->{listen}->{$server_name}->{on_disconnected}->($self,$client);

	$select->remove($client);
	close $client if $client;
}

sub start{
	my $self=shift;
	my $current_time=time;

	$select = IO::Select->new();
	foreach (keys %{$self->{listen}}) {
		print "Listen on ".$self->{listen}->{$_}->{local_address}.":".
			$self->{listen}->{$_}->{local_port}."\n";
		$select->add($self->{listen}->{$_}->{socket});
	}

	open(FILE,">".$self->{pidfile})
			or die "Cannot write PID file: $!\n";
	print FILE $$;
	close(FILE);

	while (1) {
		my $client;
		my $rv;
    		my $data;

		# cron
		my $this_time=time;
		if ($current_time != $this_time) {
		  foreach $client($select->handles) {
		    next if exists $map_sock{$client};

		    if ($turn_timeout{$client} != -1) {
		      if ($turn_timeout{$client} <= 0) {
			&{$turn_timeout_trigger{$client}}($self,$client);
			delete $turn_timeout_trigger{$client};
			$turn_timeout{$client} = -1;
		      } else {
			--$turn_timeout{$client};
		      }
		    } 
		  }

		  $self->onSheddo;
		  $current_time=$this_time;
		}

		#timeout the Idles

		foreach $client ($select->handles) {
			next if exists $map_sock{$client};
			my $server_name=$self->get_server_name($client);

			my $this_time=time;
			if( $this_time - $idle{$client} >= $self->{listen}->{$server_name}->{timeout} ){
				$self->erase_client($server_name,$client);
				next;
			}
		}
		# check for new information on the connections we have

		# anything to read or accept?
    		foreach $client ($select->can_read(1)) {
			my $server_name=$self->get_server_name($client);
			if (exists $map_sock{$client}) {
            			# accept a new connection
				$client = $self->{listen}->{$server_name}->{socket}->accept();
				unless ($client) {
					warn "Accepting new socket error: $!\n";
					next;
				}

				$select->add($client);
				$self->nonblock($client);
				$self->{listen}->{$server_name}->{on_connected}->($self,$client);

				$idle{$client}=time;
				$turn_timeout{$client}=-1;
			} else {
            			# read data

				$data = '';
				$rv   = $client->recv($data, POSIX::BUFSIZ, 0);

				unless (defined($rv) && length $data) {
                			# This would be the end of file, so close the client
					$self->erase_client($server_name,$client);
					next;
				}

				$inbuffer{$client} .= $data;

				# test whether the data in the buffer or the data we
				# just read means there is a complete request waiting
				# to be fulfilled.  If there is, set $ready{$client}
				# to the requests waiting to be fulfilled.
				my $dm=$self->{listen}->{$server_name}->{delimiter};
				my $sf=$self->{listen}->{$server_name}->{string_format};

				while ($inbuffer{$client} =~ s/($sf)$dm//s) {
					push( @{$ready{$client}}, $1 );
				}

				$idle{$client}=time;
			}
		}

		# Any complete requests to process?
		foreach $client (keys %ready) {
			my $server_name=$self->get_server_name($client);
			$self->handle($server_name,$client);
		}

		my @bad_client;

		# Buffers to flush?
		foreach $client ($select->can_write(1)) {
			my $server_name=$self->get_server_name($client);

			# Skip this client if we have nothing to say
			next unless exists $outbuffer{$client};

			eval{
				$rv = $client->send($outbuffer{$client}, 0);
			};
			push(@bad_client,$client),next if $@;

			unless (defined $rv) {
            			# Whine, but move on.

				warn "I was told I could write, but I can't.\n";
				next;
			}

			if ( $rv == length $outbuffer{$client} || $! == POSIX::EWOULDBLOCK) {
				substr($outbuffer{$client}, 0, $rv) = '';
				delete $outbuffer{$client} unless length $outbuffer{$client};
			} else {
				# Couldn't write all the data, and it wasn't because
				# it would have blocked.  Shutdown and move on.

				$self->{listen}->{$server_name}->($self,$client);
				next;
			}
		}

		foreach $client (@bad_client){
			my $server_name=$self->get_server_name($client);
			$self->erase_client($server_name,$client);
		}

		# Out of band data?
		foreach $client ($select->has_exception(0)) {
			# arg is timeout
        		# Deal with out-of-band data here, if you want to.
		}
	}

}

sub onSheddo{
	my $self=shift;

	foreach (sort {$a <=> $b} keys %timer) {
	  unless ($cronCounter % $_) {
	    &{$timer{$_}}($self);
	  }
	}

	++$cronCounter;
}

sub cron {
        my $self=shift;

	$timer{$_[0]}=$_[1];
}

sub select {
	my $self=shift;

	$select;
}

1;

__END__

=head1 NAME

Net::Server::NonBlocking - An object interface to non-blocking I/O server engine

=head1 SYNOPSIS

	use Net::Server::NonBlocking;
	$|=1;

	$obj=Net::Server::NonBlocking->new();
	$obj->add({
		server_name => 'tic tac toe',
		local_port => 10000,
		timeout => 60,
		delimiter => "\n",
		on_connected => \&ttt_connected,
		on_disconnected => \&ttt_disconnected,
		on_recv_msg => \&ttt_message
	});
	$obj->add({
		server_name => 'chess',
		local_port => 10001,
		timeout => 120,
		delimiter => "\r\n",
		on_connected => \&chess_connected,
		on_disconnected => \&chess_disconnected,
		on_recv_msg => \&chess_message
	});

	$obj->start;

=head1 DESCRIPTION

You can use this module to establish non-blocking style TCP servers without being messy with the hard monotonous routine work.

This module is not state-of-the-art of non-blocking server, it consumes some additional memories and executes some extra lines to support features which can be consider wasting if you do not plan to use. However, at present, programming time is often more expensive than RAM and CPU clocks.

=head1 FEATURES

*Capable of handling multiple server in a single process

It is possible since it uses "select" to determine which server has events, then delivers them to some appropriate methods.

*Timer

You can tell the module to execute some functions every N seconds.

*Timeout

Clients that are idle(sending nothing) in server for a configurable period will be disconnected.

*Turn timeout

The meaning of this feature is hard to explain without stimulating a case. Supposing that you write a multi-player turn-based checker server, you have to limit the times that each users spend before sending their move which can easily achieve by client side clock, however, it is not secure. That's why I have to write this feature.

=head2 USAGE

Even though, the module make it easy to build a non-blocking I/O server, but I don't expect you to remeber all its usages. Here is the template to build a server:

	use Net::Server::NonBlocking;
	$SIG{PIPE}='IGNORE';
	$|=1;

	$obj=Net::Server::NonBlocking->new();
	$obj->add({
		server_name => 'tic tac toe',
		local_port => 10000,
		timeout => 60,
		delimiter => "\n",
		on_connected => \&ttt_connected,
		on_disconnected => \&ttt_disconnected,
		on_recv_msg => \&ttt_message
	});
	$obj->add({
		server_name => 'chess',
		local_port => 10001,
		timeout => 120,
		delimiter => "\r\n",
		on_connected => \&chess_connected,
		on_disconnected => \&chess_disconnected,
		on_recv_msg => \&chess_message
	});

	sub ttt_connected {
		my $self=shift;
		my $client=shift;

		print $client "welcome to tic tac toe\n";
	}
	sub ttt_disconnected {
		my $self=shift;
		my $client=shift;

		print "a client disconnects from tic tac toe\n";
	}
	sub ttt_message {
		my $self=shift;
		my $client=shift;
		my $message=shift;

		# process $message
	}

	sub chess_connected {
		my $self=shift;
		my $client=shift;

		print $client "welcome to chess server\r\n";
	}
	sub chess_disconnected {
		my $self=shift;
		my $client=shift;

		print "a client disconnects from chess server\n";
	}
	sub chess_message {
		my $self=shift;
		my $client=shift;
		my $message=shift;

		# process $message
	}

	$obj->start;

You can pass a parameter to the "new method". It is something like this:

	->new({
			pidfile => '/var/log/pidfile'
		});

However, when ignoring this parameter, the pidfile will be
	 '/tmp/anonymous_server' by default.

The "add medthod" has various parameters which means:

*Mandatory parameter

	-server_name	different text string to distinguish a server from others

	-local_port	listening port of the added server

*Optional parameter

	-local_address: If your server has to listen all addresses in its machine, you must not pass this parameter, otherwise my internal logic will screw up. This parameter should be specify when you want to listen to a specific address. For example,

		local_address => '203.230.230.114'

	-delimiter: Every sane protocol should have a or some constant characters for splitting a chunk of texts to messages. If your protocol has inconsistent delimiters, you should write your own code.

		Default is "\0"

	-string_format: By default, string format is ".*?". In the parsing process, the module executes something like this "while ($buffer =~ s/($string_format)$delimiter//) {" and throw $1 to on_recv_msg. In the case that your protocol has no "delimiter" and each message is a single character, you might have to do this:

			delimiter => '',
			string_format => '.'

	-timeout: to set timeout for idle clients, the default value is 300 or 5 minutes

	-on_connected: call back method for an incoming client, parameters passed to this call back is illustrated with this code:

		sub {
			my $self=shift;
			my $client=shift;
		}

	- on_disconnected: call back method when a client disconnects

		sub {
			my $self=shift;
			my $client=shift;
		}

	- on_recv_msg: call back method when a client sends a message to server

		sub {
			my $self=shift;
			my $client=shift;
			my $message=shift;
		}

If you want to set a timer. You have to do something like this before calling "start" method:

	$obj->cron(30,sub {
			my $self=shift;
			#do something
		});

30 is seconds that the CODE will be triggered.
For setting turn timeout:

	$obj->start_turn($client,$limit_time, sub {
						my $self=shift;
						my $client=shift;

						# mark this client as the loser
					};

	$obj->reset_turn($client); #to clear limit_timer for a client

Let's see another usage for turn timer:

	sub kuay {
		my $self=shift;
		my $client=shift;

		print "timeout !\n";
        }

        my $toggle=0;

        sub chess_message {
            my $self=shift;
            my $client=shift;
            my $request=shift;

            $toggle^=1;

            if ($toggle) {
                $self->start_turn($client,2*60,\&kuay);
            } else {
                $self->stop_time($client);
            }
        }


=head2 EXPORT

None

=head1 SEE ALSO

There're always more than one way to do it, see "Perl Cook Book" in non-blocking I/O section.

POE -- a big module to do concurrent processing

IO::Multiplex -- I/O Multiplexing server style, the only little thing that differ to this module is that the module assumes that all clients' messages are arriving fast. Entire server will be slow down if there are a group of clients whose messages are delays which are generally caused by their internet connection.

Net::Server -- another server engine implementations such as forking, preforking or multiplexing

=head1 AUTHOR

Komtanoo  Pinpimai <romerun@romerun.com>

=head1 COPYRIGHT AND LICENSE

Copyright 2002 by root

Copyright 2002 (c) Komtanoo  Pinpimai <romerun@romerun.com>. All rights reserved. 

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself. 

=cut
