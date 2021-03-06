package Qdup::Manager;

use strict;
use warnings;

use FindBin qw/$Bin/;
use Proc::Daemon;
use Qdup::Common;

sub new {
    my $class = shift;
    my (%params) = @_; 
    my $self = bless \%params, ref $class || $class;

    $self->{pool} = defined $self->{pool} ? $self->{pool} : 1;  # handles when pool == 0
    $self->{table}    ||= 'qdup_jobs';
    $self->{queue}    ||= 'main';
    $self->{work_dir} ||= "$Bin/../log";

    $self->{host} = `hostname`;
    chomp($self->{host});

    $self->{workers}      = {};
    $self->{exec_command} = 'qdup_worker';
    $self->{exec_command} .= " --table $self->{table}";
    $self->{exec_command} .= " --queue $self->{queue}";
    $self->{exec_command} .= " --lib $self->{lib}"   if defined $self->{lib};
    $self->{exec_command} .= " --pool $self->{pool}" if defined $self->{pool};

    open $self->{LOG}, ">> $self->{work_dir}/qdup_manager.$self->{queue}.log";

    $self->{daemon} = Proc::Daemon->new(
        work_dir     => $self->{work_dir},
        exec_command => $self->{exec_command}
    );

    return $self;
}

sub log {
    my ($self, $msg) = @_;
    chomp($msg);
    my $ts = `date +"%Y-%m-%d %H:%M:%S"`;
    chomp($ts);
    print { $self->{LOG} } "$ts : $msg\n";
}

sub release {
    my ($self, $worker) = @_;
    eval {
        # Mark abandoned jobs as WAITING, so they will be picked up for execution again
        Qdup::Common::db_do(
            "UPDATE qdup_jobs
                SET worker   = '',
                    status   = 'WAITING',
                    end_time = now()
              WHERE worker = '$worker'"
        );
    };
    if (my $err = $@) {
        $self->log("ERROR releasing worker ($self->{worker}) in qdup_jobs table");
    }
}

sub run {
    my $self = shift;

    # Run a one-liner to find pid files and extract their id and pid values
    open WORKER_IDS, "grep -HE '.' $self->{work_dir}/qdup_worker.$self->{queue}.*.pid | sed -E 's/.*\\.([0-9]+)\\.pid/\\1/' |";
        WORKER:
        while (my $worker_pid = <WORKER_IDS>) {
            chomp($worker_pid);
            my ($id, $pid) = split /:/, $worker_pid;

            if ($id <= $self->{pool}) {
                if ($self->{daemon}->Status($pid) > 0) {
                    # It's running as expected; mark the running pid and go to the next worker
                    $self->{workers}->{$id} = $pid;
                    next WORKER;
                }
                # else { don't record the pid; continue to release call and unlink pid file below }
            } else {
                # Kill this job since we're over the pool size
                my $procs_killed = $self->{daemon}->Kill_Daemon($pid);
                if (0 == $procs_killed) {
                    $self->log("Failed to kill pid $pid");
                } else {
                    $self->log("Killed pid $pid");
                }
            }
            $self->release("$self->{host}:$pid");
            unlink "$self->{work_dir}/qdup_worker.$self->{queue}.$id.pid";
        }        
    close WORKER_IDS;

    foreach my $id (1..$self->{pool}) {
        $self->{workers}->{$id} ||= Proc::Daemon::Init(
          { work_dir     => $self->{work_dir},
            pid_file     => "$self->{work_dir}/qdup_worker.$self->{queue}.$id.pid",
            exec_command => $self->{exec_command} . " --id $id" }  # add the id to the exec command
        );
        $self->log("Worker $id with pid $self->{workers}->{$id}");
    }

    if (0 == $self->{pool}) {
        Qdup::Common::db_do( [
            "UPDATE qdup.qdup_jobs
                SET status = 'WAITING',
                    worker = '',
                    begin_time = null
              WHERE status = 'RUNNING'
                AND queue = '$self->{queue}'"
        ] );
    }
}

sub DESTROY {
    my $self = shift;
    close $self->{LOG} if $self->{LOG};
}

1;
