# Derived from perl5db.pl
# Tracks calls and returns and stores some stack frame
# information.
package DB;
use warnings; no warnings 'redefine'; use utf8;
no warnings 'once';
use English qw( -no_match_vars );

use constant SINGLE_STEPPING_EVENT =>   1;
use constant NEXT_STEPPING_EVENT   =>   2;
use constant DEEP_RECURSION_EVENT  =>   4;
use constant RETURN_EVENT          =>  32;
use constant CALL_EVENT            =>  64;

use vars qw($return_value @return_value @ret $ret @stack %fn_brkpt $deep);

BEGIN {
    @DB::ret = ();    # return value of last sub executed in list context
    $DB::ret = '';    # return value of last sub executed in scalar context
    $DB::return_type = 'undef';
    %DB::fn_brkpt    = ();

    # $deep: Maximium stack depth before we complain.
    # See RT #117407
    # https://rt.perl.org/rt3//Public/Bug/Display.html?id=117407
    # for justification for why this should be 1000 rather than something
    # smaller.
    $DB::deep = 500;

    # $stack_depth is to track the current stack depth using the
    # auto-stacked-variable trick. It is 'local'ized repeatedly as
    # a simple way to keep track of #stack.
    $DB::stack_depth = 0;
    @DB::stack = (0);     # Per-frame debugger flags
}

sub subcall_debugger {
    if ($DB::single || $DB::signal) {
        _warnall($#DB::stack . " levels deep in subroutine calls.\n") if $DB::single & 4;
	local $DB::event = 'call';
        $DB::single = 0;
        $DB::signal = 0;
        $DB::running = 0;

	# lock the debugger and get the thread id for the prompt
	if ($ENV{PERL5DB_THREADED}) {
	    require threads;
	    require threads::shared;
	    import threads::shared qw(share);
	    no strict; no warnings;
	    lock($DBGR);
	    $tid = eval { "[".threads->tid."]" };
	}

	local $OP_addr =
	    ($HAVE_MODULE{'Devel::Callsite'} &&
	     $Devel::Callsite::VERSION >= 0.08)
	    ? Devel::Callsite::callsite(1) : undef;

	$DB::subroutine =  $sub;
	my $entry = $DB::sub{$sub};
	if ($entry =~ /^(.*)\:(\d+)-(\d+)$/) {
	    $DB::filename   = $1;
	    $DB::lineno     = $2;
	    $DB::caller = [
		$DB::filename, $DB::lineno, $DB::subroutine,
		0 != scalar(@_), $DB::wantarray
		];
	}
        for my $c (@clients) {
            # Now sit in an event loop until something sets $running
            my $after_eval = 0;
            do {
                # Show display expresions
                my $display_aref = $c->display_lists;
                for my $disp (@$display_aref) {
                    next unless $disp && $disp->enabled;
                    my $opts = {return_type => $disp->return_type,
                                namespace_package => $namespace_package,
                                fix_file_and_line => 1,
                                hide_position     => 0};
                    # FIXME: allow more than just scalar contexts.
		    &DB::save_vars();
                    my $eval_result =
                        &DB::eval_with_return($disp->arg, $opts, @DB::saved);
		    my $mess;
		    if (defined($eval_result)) {
			$mess = sprintf("%d: $eval_result", $disp->number);
		    } else {
			$mess = sprintf("%d: undef", $disp->number);
		    }
                    $c->output($mess);
                }

                if (1 == $after_eval ) {
                    $event = 'after_eval';
                } elsif (2 == $after_eval) {
                    $event = 'after_nest'
                }

                # call client event loop; must not block
                $c->idle($event, $watch_triggered);
                $after_eval = 0;
                if ($running == 2 && defined($eval_str)) {
                    # client wants something eval-ed
                    # FIXME: turn into subroutine.

                    local $nest = $eval_opts->{nest};
                    my $return_type = $eval_opts->{return_type};
                    $return_type = '' unless defined $return_type;
                    my $opts = $eval_opts;
                    $opts->{namespace_package} = $namespace_package;

		    &DB::save_vars();
                    if ('@' eq $return_type) {
                        &DB::eval_with_return($eval_str, $opts, @DB::saved);
                    } elsif ('%' eq $return_type) {
                        &DB::eval_with_return($eval_str, $opts, @DB::saved);
                    } else {
                        $eval_result =
                            &DB::eval_with_return($eval_str, $opts, @DB::saved);
                    }

                    if ($nest) {
                        $DB::in_debugger = 1;
                        $after_eval = 2;
                    } else {
                        $after_eval = 1;
                    }
                    $running = 0;
                }
            } until $running;
        }
    }
}

sub check_for_stop() {
    my $brkpts = $DB::fn_brkpt{$sub};
    if ($brkpts) {
	my @action = ();
        for (my $i=0; $i < @$brkpts; $i++) {
            my $brkpt = $brkpts->[$i];
            next unless defined $brkpt;
            if ($brkpt->type eq 'action') {
                push @action, $brkpt;
                next ;
            }
            $stop = 0;
            if ($brkpt->condition eq '1') {
                # A cheap and simple test for unconditional.
                $stop = 1;
            } else  {
                my $eval_str = sprintf("\$DB::stop = do { %s; }",
                                       $brkpt->condition);
                my $opts = {return_type => ';',  # ignore return
                            namespace_package => $namespace_package,
                            fix_file_and_line => 1,
                            hide_position     => 0};
		&DB::save_vars();
                &DB::eval_with_return($eval_str, $opts, @DB::saved);
            }
            if ($stop && $brkpt->enabled && !($DB::single & RETURN_EVENT)) {
                $DB::brkpt = $brkpt;
                $event = $brkpt->type;
                if ($event eq 'tbrkpt') {
                    # breakpoint is temporary and remove it.
                    undef $brkpts->[$i];
                } else {
                    my $hits = $brkpt->hits + 1;
                    $brkpt->hits($hits);
                }
		$DB::single = 1;
		$DB::wantarray = wantarray;
		local $OP_addr =
		    ($HAVE_MODULE{'Devel::Callsite'} &&
		     $Devel::Callsite::VERSION >= 0.08)
		    ? Devel::Callsite::callsite(1) : undef;
		&subcall_debugger() ;
                last;
            }
        }
    }
}

# Push the $DB:single onto @DB::stack and set $DB_single.
sub push_DB_single_and_set()
{
    # Expand @stack.
    $#DB::stack = $DB::stack_depth;

    # Save current single-step setting.
    $DB::stack[-1] = $DB::single;

    # printf "++ \$DB::single for $sub: 0%x\n", $DB::single if $DB::single;
    # Turn off all flags except single-stepping or return event.
    $DB::single &= SINGLE_STEPPING_EVENT;

    # If we've gotten really deeply recursed, turn on the flag that will
    # make us stop with the 'deep recursion' message.
    $DB::single |= DEEP_RECURSION_EVENT if $#stack == $deep;
}


####
# When debugging is enabled, this routine gets called instead of
# the orignal subroutine. $DB::sub contains the intended subroutine
# to be called. Thus, this routine must run &$DB::sub
# in order to get the original routine called. The fact that
# this routine is called instead allows us to wrap or put code
# around subroutine calls
#
sub DB::sub {
    # Do not use a regex in this subroutine -> results in corrupted
    # memory See: [perl #66110]

    # lock ourselves under threads
    lock($DBGR) if $ENV{PERL5DB_THREADED};

    # Whether or not the autoloader was running, a scalar to put the
    # sub's return value in (if needed), and an array to put the sub's
    # return value in (if needed).
    my ( $al, $ret, @ret ) = "";
    if ($DB::sub eq 'threads::new' && $ENV{PERL5DB_THREADED}) {
        print "creating new thread\n";
    }

    # If the last ten characters are '::AUTOLOAD', note we've traced
    # into AUTOLOAD for $DB::sub.
    if ( length($DB::sub) > 10 && substr( $DB::sub, -10, 10 ) eq '::AUTOLOAD' ) {
        no strict 'refs';
        $al = " for $$DB::sub" if defined $$DB::sub;
    }

    # We stack the stack pointer and then increment it to protect us
    # from a situation that might unwind a whole bunch of call frames
    # at once. Localizing the stack pointer means that it will automatically
    # unwind the same amount when multiple stack frames are unwound.
    local $stack_depth = $stack_depth + 1;    # Protect from non-local exits
    push_DB_single_and_set();

    if (defined($DB::running) && $DB::running == 1) {
	local @DB::_ = @_;
	check_for_stop();
    }

    if ($DB::sub eq 'DESTROY' or
        substr($DB::sub, -9) eq '::DESTROY' or not defined wantarray) {
        &$DB::sub;
        $DB::single |= pop(@stack);
        $DB::ret = undef;
    }
    elsif (wantarray) {
        # Called in array context. call sub and capture output.
        # DB::DB will recursively get control again if appropriate;
        # we'll come back here when the sub is finished.

	{
	    no strict 'refs';
	    # call the original subroutine and save the array value.
	    @ret = &$DB::sub;
	}

        # Pop the single-step value back off the stack.
        $DB::single |= $stack[ $stack_depth-- ];
        if ($single & RETURN_EVENT) {
            $DB::return_type = 'array';
            @DB::return_value = @ret;
            DB::DB($DB::sub) ;
            return @DB::return_value;
        }
        @ret;
    } else {
        # Called in array context. call sub and capture output.
        # DB::DB will recursively get control again if appropriate;
        # we'll come back here when the sub is finished.

        if ( defined wantarray ) {
            no strict 'refs';
	    # call the original subroutine and save the array value.
            $ret = &$DB::sub;
        } else {
            no strict 'refs';
	    # Call the original lvalue sub and explicitly void the return
            # value.
            &$DB::sub;
            undef $ret;
        }

        # Pop the single-step value back off the stack.
        $DB::single |= $stack[ $stack_depth-- ] if $stack[$stack_depth];
        if ($single & RETURN_EVENT) {
            $DB::return_type = defined $ret ? 'scalar' : 'undef';
            $DB::return_value = $ret;
            DB::DB($DB::sub) ;
            return $DB::return_value;
        }

        # Return the appropriate scalar value.
        return $ret;
    }
}

####
# When debugging is enabled, this routine gets called instead of the
# orignal subroutine in a left-hand (assignment) context. $DB::sub
# contains the intended subroutine to be called. Thus, this routine
# must run &$DB::sub in order to get the original routine called. The
# fact that this routine is called instead allows us to wrap or
# instrument code around subroutine calls.
#
sub DB::lsub : lvalue {
    # Possibly [perl #66110] also applies here as in sub.

    # lock ourselves under threads
    lock($DBGR) if $ENV{PERL5DB_THREADED};

    # Whether or not the autoloader was running, a scalar to put the
    # sub's return value in (if needed), and an array to put the sub's
    # return value in (if needed).
    my ( $al, $ret, @ret ) = "";
    if ($DB::sub =~ /^threads::new$/ && $ENV{PERL5DB_THREADED}) {
        print "creating new thread\n";
    }

    # If the last ten characters are '::AUTOLOAD', note we've traced
    # into AUTOLOAD for $DB::sub.
    if ( length($DB::sub) > 10 && substr( $DB::sub, -10, 10 ) eq '::AUTOLOAD' ) {
        $al = " for $$DB::sub" if defined $$DB::sub;;
    }

    # We stack the stack pointer and then increment it to protect us
    # from a situation that might unwind a whole bunch of call frames
    # at once. Localizing the stack pointer means that it will automatically
    # unwind the same amount when multiple stack frames are unwound.
    local $stack_depth = $stack_depth + 1;    # Protect from non-local exits
    push_DB_single_and_set();

    check_for_stop();

    if (wantarray) {
        # Called in array context. call sub and capture output.
        # DB::DB will recursively get control again if appropriate; we'll come
        # back here when the sub is finished.
	{
	    no strict 'refs';
	    @ret = &$DB::sub;
	}

        # Pop the single-step value back off the stack.
        $DB::single |= $stack[ $stack_depth-- ];
        if ($DB::single & RETURN_EVENT) {
            $DB::return_type = 'array';
            @DB::return_value = @ret;
            DB::DB($DB::sub) ;
            return @DB::return_value;
        }
        @ret;
    } else {
        # Called in array context. call sub and capture output.
        # DB::DB will recursively get control again if appropriate;
        # we'll come back here when the sub is finished.

        if ( defined wantarray ) {
            no strict 'refs';
            # Save the value if it's wanted at all.
            $ret = &$DB::sub;
        } else {
            no strict 'refs';
            # Void return, explicitly.
            &$DB::sub;
            undef $ret;
        }

        # Pop the single-step value back off the stack.
        $DB::single |= $stack[ $stack_depth-- ] if $stack[$stack_depth];
        if ($DB::single & RETURN_EVENT) {
            $DB::return_type = defined $ret ? 'scalar' : 'undef';
            $DB::return_value = $ret;
            DB::DB($DB::sub) ;
            return $DB::return_value;
        }

        # Return the appropriate scalar value.
        return $ret;
    }
}

####
# without args: returns all defined subroutine names
# with subname args: returns a listref [file, start, end]
#
sub subs {
  my $s = shift;
  if (@_) {
    my(@ret) = ();
    while (@_) {
      my $name = shift;
      push @ret, [$DB::sub{$name} =~ /^(.*)\:(\d+)-(\d+)$/]
        if exists $DB::sub{$name};
    }
    return @ret;
  }
  return keys %DB::sub;
}

1;
