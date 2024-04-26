package Permission;

use strict;
use warnings;

use PAUSE::Permissions ();
use Getopt::Long;
use MetaCPAN::Logger qw< :log :dlog >;

use MetaCPAN::ES;
use MetaCPAN::Ingest qw<
    config
    cpan_dir
>;

# args
my $cleanup;
GetOptions( "cleanup" => \$cleanup );

# setup
my $config = config();
$config->init_logger;

my $cpan   = cpan_dir();
my $es     = MetaCPAN::ES->new( type => "permission" );
my $bulk   = $es->bulk();
my $scroll = $es->scroll();

my $file_path = $cpan->child(qw< modules 06perms.txt >)->absolute;
my $pp        = PAUSE::Permissions->new( path => $file_path );

my %seen;
log_debug {"building permission data to add"};

my $iterator = $pp->module_iterator;
while ( my $perms = $iterator->next_module ) {

    # This method does a "return sort @foo", so it can't be called in the
    # ternary since it always returns false in that context.
    # https://github.com/neilb/PAUSE-Permissions/pull/16

    my $name = $perms->name;

    my @co_maints = $perms->co_maintainers;
    my $doc       = {
        module_name => $name,
        owner       => $perms->owner,

        # empty list means no co-maintainers
        # and passing the empty arrayref will force
        # deleting existingd values in the field.
        co_maintainers => \@co_maints,
    };

    $bulk->update(
        {
            id            => $name,
            doc           => $doc,
            doc_as_upsert => 1,
        }
    );

    $seen{$name} = 1;
}

$bulk->flush;

run_cleanup( \%seen ) if $cleanup;

log_info {'done indexing 06perms'};

sub _get_authors_data {
    my ($authors_file) = @_;

    my $data = XMLin(
        $authors_file,
        ForceArray    => 1,
        SuppressEmpty => '',
        NoAttr        => 1,
        KeyAttr       => [],
    );

    my $whois_data = {};

    for my $author ( @{ $data->{cpanid} } ) {
        my $data = {
            map {
                my $content = $author->{$_};
                @$content == 1
                    && !ref $content->[0] ? ( $_ => $content->[0] ) : ();
            } keys %$author
        };

        my $id       = $data->{id};
        my $existing = $whois_data->{$id};
        if (  !$existing
            || $existing->{type} eq 'author' && $data->{type} eq 'list' )
        {
            $whois_data->{$id} = $data;
        }
    }

    return $whois_data;
}

sub run_cleanup {
    my ($seen) = @_;

    log_debug {"checking permission data to remove"};

    my @remove;

    my $count = $scroll->total;
    while ( my $p = $scroll->next ) {
        my $id = $p->{_id};
        unless ( exists $seen->{$id} ) {
            push @remove, $id;
            log_debug {"removed $id"};
        }
        log_debug { $count . " left to check" } if --$count % 10000 == 0;
    }

    $bulk->delete_ids(@remove);
    $bulk->flush;
}

1;

__END__
