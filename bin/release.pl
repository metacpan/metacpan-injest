use strict;
use warnings;
use v5.36;

use CPAN::Meta         ();
use CPAN::DistnameInfo ();
use File::Find::Rule   ();
use File::stat         ();
use Getopt::Long;
use List::Util qw< uniq >;
use Path::Tiny qw< path >;
use PerlIO::gzip;
use Try::Tiny qw< catch try >;

use MetaCPAN::Logger qw< :log :dlog >;

use MetaCPAN::Archive;
use MetaCPAN::ES;
use MetaCPAN::Ingest qw<
    author_dir
    cpan_dir
    cpan_file_map
    digest
    extract_section
    fix_version
    handle_error
    minion
    strip_pod
    tmp_dir
    ua
>;

use MetaCPAN::Release;

my @skip_dists = (

    # specific dists to skip.  it's ugly to have all of these hard coded, but
    # it works for now
    qw<
        AEPAGE/perl5.00502Tk800.011-win32-586.zip
        ANDYD/perl5.002b1h.tar.gz
        BMIDD/perl5.004_02-AlphaNTPreComp.tar.gz
        BMIDD/perl5.00402-bindist04-msvcAlpha.tar.gz
        BMIDD/perl5.00402-bindist05-msvcAlpha.tar.gz
        GRABZIT/perl.2.3.0.zip
        GSAR/perl5.00401-bindist02-bc.tar.gz
        GSAR/perl5.00401-bindist-bc.tar.gz
        GSAR/perl5.00402-bindist03-bc.tar.gz
        GSAR/perl5.00402-bindist04-bc.tar.gz
        GSAR/perl5.00402-bindist04-bc.zip
        HOOO/perl-0.0017.tar.gz
        JBAKER/perl-5.005_02+apache1.3.3+modperl-1.16-bin-bindist1-i386-win32-vc5.zip
        KRISHPL/perl-5.6-info.tar.gz
        LMOLNAR/perl5.00402-bindist01-dos-djgpp.zip
        LMOLNAR/perl5.00503-bin-1-dos-djgpp.zip
        MSCHWERN/perl-1.0_15.tar.gz
        RCLAMP/perl-1.0_16.tar.gz
        SREZIC/perl-5.005-basicmods-bin-0-arm-linux.tar.gz
        SREZIC/perl-5.005-minimal-bin-0-arm-linux.tar.gz
        SREZIC/perl-5.005-minimal-bin-1-arm-linux.tar.gz
        SREZIC/perl-5.005-Tk-800.023-bin-0-arm-linux.tar.gz
    >,

# ILYAZ has lots of old weird os2 files that don't fit as dists or perl releases
    qr{/ILYAZ/os2/[^/]+/perl_\w+\.zip\z},
    qr{/ILYAZ/os2/perl[^/]+\.zip\z},

    # Strip off any files in a Perl6 or Raku folder
    # e.g. http://www.cpan.org/authors/id/J/JD/JDV/Perl6/
    # As here we are indexing perl5 only
    qr{/(?:Perl6|Raku)/},
);

my ($SKIP_MATCH) = map qr/$_/, join '|',
    map +( ref $_ ? $_ : qr{/\Q$_\E\z} ), @skip_dists;

my @always_no_index_dirs = (

    # Always ignore the same dirs as PAUSE (lib/PAUSE/dist.pm):
    ## skip "t" - libraries in ./t are test libraries!
    ## skip "xt" - libraries in ./xt are author test libraries!
    ## skip "inc" - libraries in ./inc are usually install libraries
    ## skip "local" - somebody shipped his carton setup!
    ## skip 'perl5" - somebody shipped her local::lib!
    ## skip 'fatlib' - somebody shipped their fatpack lib!
    qw< t xt inc local perl5 fatlib >,

    # and add a few more
    qw< example blib examples eg >,
);

my $RE_SECTION = qr/^\s*(\S+)((\h+-+\h+(.+))|(\r?\n\h*\r?\n\h*(.+)))?/ms;

my @NOT_PERL_FILES = qw(SIGNATURE);

# args
my ( $age, $bulk_size, $detect_backpan, $force_authorized, $latest, $queue,
    $skip, $status );
GetOptions(
    "age=i"            => \$age,
    "bulk_size=i"      => \$bulk_size,
    "detect_backpan"   => \$detect_backpan,
    "force_authorized" => \$force_authorized,
    "latest"           => \$latest,
    "queue"            => \$queue,
    "skip"             => \$skip,
    "status"           => \$status,
);
$status //= 'cpan';

# setup
my $ua   = ua();
my $cpan = cpan_dir();
my $es   = MetaCPAN::ES->new( type => "release" );

#my $bulk = $es->bulk( size => $bulk_size );

my $minion;
$minion = minion() if $queue;

# run

my $perms = _perms();

my @files;
for (@ARGV) {
    if ( -d $_ ) {
        log_info {"Looking for archives in $_"};
        my $find = File::Find::Rule->new->file->name(
            qr/\.(tgz|tbz|tar[\._-]gz|tar\.bz2|tar\.Z|zip|7z)$/);
        $find = $find->mtime( ">" . ( time - $age * 3600 ) )
            if $age;
        push( @files,
            map      { $_->{file} }
                sort { $a->{mtime} <=> $b->{mtime} }
                map  { +{ file => $_, mtime => File::stat::stat($_)->mtime } }
                $find->in($_) );
    }
    elsif ( -f $_ ) {
        push( @files, $_ );
    }
    elsif ( $_ =~ /^https?:\/\//
        && CPAN::DistnameInfo->new($_)->cpanid )
    {
        my $dist = CPAN::DistnameInfo->new($_);

        my $file = tmp_dir( author_dir( $dist->cpanid ), $dist->filename, );
        $file->parent->mkpath;
        log_info {"Downloading $_"};

        $ua->parse_head(0);
        $ua->timeout(30);
        $ua->mirror( $_, $file );
        if ( -e $file ) {
            push( @files, $file );
        }
        else {
            log_error {"Downloading $_ failed"};
        }
    }
    else {
        log_error {"Dunno what $_ is"};
    }
}

@files = grep $_ !~ $SKIP_MATCH, @files;

log_info { scalar @files, " archives found" } if ( @files > 1 );

# build here before we fork

# Going to purge everything as not sure about the 'skip' or fork
# logic - feel free to clean up so the CP::DistInfo isn't
my @module_to_purge_dists = map { CPAN::DistnameInfo->new($_) } @files;

my $cpan_file_map;
$cpan_file_map = cpan_file_map if $detect_backpan;

my @pid;

eval { DB::enable_profile() };
while ( my $file = shift @files ) {
    my $dist = CPAN::DistnameInfo->new($file);

    if ($skip) {
        my $count = $es->count(
            body => {
                query => {
                    bool => {
                        must => [
                            { term => { archive => $dist->filename } },
                            { term => { author  => $dist->cpanid } },
                        ]
                    }
                }
            },
        );

        if ( $count->{count} ) {
            log_info {"Skipping $file"};
            next;
        }
    }

    if ($queue) {
        my $job_id = $minion->enqueue(
            index_release => [$file],
            { attempts => 3, priority => 3 }
        );

        # This is a hack to deal with the fact that we don't know exactly
        # when 02packages gets updated.  As of 2019-04-08, 02packages is
        # updated via a cron which runs every 12 minutes, with the
        # exception of one run which is skipped, resulting in a 24 minute
        # gap.  The run usually takes less than one minute.  We could stop
        # trying once something is already "latest", but some uploads will
        # never be "latest".  Trying this X times should be fairly cheap.
        # If this doesn't work, there is a cleanup cron which can set the
        # "latest" flag, if necessary.

        if ($latest) {
            for my $delay ( 2 * 60, 7 * 60, 14 * 60, 26 * 60 ) {
                $minion->enqueue(
                    index_latest => [ '--distribution', $dist->dist ] => {
                        attempts => 3,
                        delay    => $delay,
                        parents  => [$job_id],
                        priority => 2,
                    }
                );
            }
        }

    }
    else {
        try { _import_archive( $file, $dist ) }
        catch {
            handle_error( "$file $_[0]", 1 );
        };
    }
}
$es->index_refresh unless $queue;

# Call Fastly to purge
# purge_cpan_distnameinfos( \@module_to_purge_dists );

# subs

sub _index_files ($files) {
    my $es   = MetaCPAN::ES->new( type => "file" );
    my $bulk = $es->bulk( size => $bulk_size );

    log_debug { 'Indexing ', scalar(@$files), ' files' };

    for my $f (@$files) {
        $bulk->update( {
            id => digest( $f->{author}, $f->{release}, $f->{path} )
            ,    ### ???? file name
            doc           => $f,
            doc_as_upsert => 1,
        } );
    }

    $bulk->flush;
}

sub _perms () {
    my $file = $cpan->child(qw< modules 06perms.txt >);
    my %authors;
    if ( -e $file ) {
        log_debug { "parsing ", $file };
        my $fh = $file->openr;
        while ( my $line = <$fh> ) {
            my ( $module, $author, $type ) = split( /,/, $line );
            next unless ($type);
            $authors{$module} ||= [];
            push( @{ $authors{$module} }, $author );
        }
        close $fh;
    }
    else {
        log_warn {"$file could not be found."};
    }

    my $packages = $cpan->child(qw< modules 02packages.details.txt.gz >);
    if ( -e $packages ) {
        log_debug { "parsing ", $packages };
        open my $fh, "<:gzip", $packages;
        while ( my $line = <$fh> ) {
            if ( $line =~ /^(.+?)\s+.+?\s+\S\/\S+\/(\S+)\// ) {
                $authors{$1} ||= [];
                push( @{ $authors{$1} }, $2 );
            }
        }
        close $fh;
    }
    return \%authors;
}

sub _detect_status ( $author, $archive ) {
    return $status unless $detect_backpan;
    if ( $cpan_file_map->{$author}{$archive} ) {
        return 'cpan';
    }
    else {
        log_debug {'BackPAN detected'};
        return 'backpan';
    }
}

sub _import_archive ( $archive_path, $dist ) {
    log_debug {'Gathering modules'};

    my $author = $dist->cpanid;
    my $status
        = $detect_backpan
        ? _detect_status( $author, $archive_path )
        : $status;

    # move creation of arc_data into the module ?
    my $release = MetaCPAN::Release->new(
        always_no_index_dirs => \@always_no_index_dirs,
        archive_path         => $archive_path,
        author               => $author,
        dist_info            => $dist,
        status               => $status,
    );

    my $files    = $release->files;
    my $modules  = $release->modules;
    my $metadata = $release->{metadata};
    my $document = $release->document_release();

    _index_files($files);

    ### TODO: check the effect of not running the builder for 'indexed'
    ###       (we already set the flag in the logic creating the 'doc')

    my %associated_pod;

    for my $f ( grep { $_->{indexed} } @$files ) {
        my $documentation = _documentation($f);
        next unless $documentation;

        $associated_pod{$documentation}
            = [ @{ $associated_pod{$documentation} || [] }, $f ];
    }

# check for release deprecation in abstract of release or has x_deprecated in meta
    my $deprecated = (
               $metadata->{x_deprecated}
            or $document->{abstract}
            and $document->{abstract} =~ /DEPRECI?ATED/
    ) ? 1 : 0;

    $document->{deprecated} = $deprecated;

    log_debug { sprintf( 'Indexing %d modules', scalar(@$modules) ) };

    my $perms = _perms();
    my @release_unauthorized;
    my @provides;

    foreach my $file (@$files) {
        _set_associated_pod( $_, \%associated_pod ) for @{ $file->{modules} };

### CONTINUE FROM HERE -

     # NOTE: "The method returns a list of unauthorized, but indexed modules."
     # push @release_unauthorized, _set_authorized($file, $perms)
     #     if keys %$perms and !$force_authorized;

        # my $file_x_deprecated = 0;

        # for ( @{ $file->module } ) {
        #     push( @provides, $_->name )
        #         if $_->indexed
        #         && ( $_->authorized || $force_authorized );
        #     $file_x_deprecated = 1
        #         if $meta->{provides}{ $_->name }{x_deprecated};
        # }
    }

    use DDP;
    &p( [@release_unauthorized] );

###

    use DDP;
    &p( [ HERE => 1 ] );
    exit;
}

=head2 set_authorized

Expects a C<$perms> parameter which is a HashRef. The key is the module name
and the value an ArrayRef of author names who are allowed to release
that module.

The method returns a list of unauthorized, but indexed modules.

Unauthorized modules are modules that were uploaded in the name of a
different author than stated in the C<06perms.txt.gz> file. One problem
with this file is, that it doesn't record historical data. It may very
well be that an author was authorized to upload a module at the time.
But then his co-maintainer rights might have been revoked, making consecutive
uploads of that release unauthorized. However, since this script runs
with the latest version of C<06perms.txt.gz>, the former upload will
be flagged as unauthorized as well. Same holds the other way round,
a previously unauthorized release would be flagged authorized if the
co-maintainership was added later on.

If a release contains unauthorized modules, the whole release is marked
as unauthorized as well.

=cut

# sub _set_authorized ( $file, $perms ) {
#     # only authorized perl distributions make it into the CPAN
#     return () if ( $file->{distribution} eq 'perl' );
# ### CONTINUE HERE ---

#     foreach my $module ( @{ $file->{modules} } ) {
#         $module->_set_authorized(0)
#             if ( $perms->{ $module->name } && !grep { $_ eq $file->author }
#             @{ $perms->{ $module->name } } );
#     }
#     $file->_set_authorized(0)
#         if ( $file->authorized
#         && $file->documentation
#         && $perms->{ $file->documentation }
#         && !grep { $_ eq $file->author }
#         @{ $perms->{ $file->documentation } } );
#     return grep { !$_->authorized && $_->indexed } @{ $file->module };
# }

sub _set_associated_pod ( $module, $associated_pod ) {
    return unless ( my $files = $associated_pod->{ $module->{name} } );

    my %_pod_score = ( pod => 50, pm => 40, pl => 30 );

    ( my $mod_path = $module->{name} ) =~ s{::}{/}g;

    my ($file) = (
        #<<<
        # TODO: adjust score if all files are in root?
        map  { $_->[1] }
        sort { $b->[0] <=> $a->[0] }    # desc
        map  {
            [ (
                # README.pod in root should rarely if ever be chosen.
                # Typically it's there for github or something and it's usually
                # a duplicate of the main module pod (though sometimes it falls
                # out of sync (which makes it even worse)).
                $_->{path} =~ /^README\.pod$/i ? -10 :

                # If the name of the package matches the name of the file,
                $_->{path} =~ m!(^lib/)?\b${mod_path}.((?i)pod|pm)$! ?
                    # Score pod over pm, and boost (most points for 'lib' dir).
                    ($1 ? 50 : 25) + $_pod_score{lc($2)} :

                # Sort files by extension: Foo.pod > Foo.pm > foo.pl.
                $_->{name} =~ /\.(pod|pm|pl)/i ? $_pod_score{lc($1)} :

                # Otherwise score unknown (near the bottom).
                -1
            ),
            $_ ]
         }
         @$files
         #>>>
    );

    $module->{associated_pod} = _full_path($file);
}

sub _full_path ($file) {
    return join( '/', @{$file}{qw< author release path >} );
}

sub _perms () {
    my $file = $cpan->child(qw< modules 06perms.txt >);
    my %authors;
    if ( -e $file ) {
        log_debug { "parsing ", $file };
        my $fh = $file->openr;
        while ( my $line = <$fh> ) {
            my ( $module, $author, $type ) = split( /,/, $line );
            next unless ($type);
            $authors{$module} ||= [];
            push( @{ $authors{$module} }, $author );
        }
        close $fh;
    }
    else {
        log_warn {"$file could not be found."};
    }

    my $packages = $cpan->child(qw< modules 02packages.details.txt.gz >);
    if ( -e $packages ) {
        log_debug { "parsing ", $packages };
        open my $fh, "<:gzip", $packages;
        while ( my $line = <$fh> ) {
            if ( $line =~ /^(.+?)\s+.+?\s+\S\/\S+\/(\S+)\// ) {
                $authors{$1} ||= [];
                push( @{ $authors{$1} }, $2 );
            }
        }
        close $fh;
    }
    return \%authors;
}

=head2 is_perl_file

Return true if the file extension is one of C<pl>, C<pm>, C<pod>, C<t>
or if the file has no extension, is not a binary file and its size is less
than 131072 bytes. This is an arbitrary limit but it keeps the pod parser
happy and the indexer fast.

=cut

sub _is_perl_file ($file) {
    return 0 if ( $file->{directory} );
    return 1 if ( $file->{name} =~ /\.(pl|pm|pod|t)$/i );
    return 1 if ( $file->{mime} eq "text/x-script.perl" );
    return 1
        if ( $file->{name} !~ /\./
        && !( grep { $file->{name} eq $_ } @NOT_PERL_FILES )
        && !$file->{binary}
        && $file->{stat}{size} < 2**17 );
    return 0;
}

sub _section ($file) {
    my $section = extract_section( $file->{content}, 'NAME' );

    # if it's a POD file without a name section, let's try to generate
    # an abstract and name based on filename
    if ( !$section && $file->{path} =~ /\.pod$/ ) {
        $section = $file->{path};
        $section =~ s{^(lib|pod|docs)/}{};
        $section =~ s{\.pod$}{};
        $section =~ s{/}{::}g;
    }

    return undef unless ($section);
    $section =~ s/^=\w+.*$//mg;
    $section =~ s/X<.*?>//mg;

    return $section;
}

=head2 documentation

Holds the name for the documentation in this file.

If the file L<is a pod file|/is_pod_file>, the name is derived from the
C<NAME> section. If the file L<is a perl file|/is_perl_file> and the
name from the C<NAME> section matches one of the modules in L</module>,
it returns the name. Otherwise it returns the name of the first module
in L</module>. If there are no modules in the file the documentation is
set to C<undef>.

=cut

sub _documentation ($file) {
    return undef unless _is_perl_file($file);

    my $section = _section($file);
    return undef unless $section;

    my $doc;

    if ( $section =~ $RE_SECTION ) {
        my $name = strip_pod($1);
        $doc = $name if $name =~ /^[\w\.:\-_']+$/;
    }

### IF documentation is set - it's already a result of strip_pod
    # $documentation = strip_pod($documentation)
    #     if $documentation;

    return undef unless length $doc;

    # Modules to be indexed
    my @indexed = grep { $_->{indexed} } @{ $file->{modules} };

    # This is a Pod file, return its name
    return $doc
        if $doc and $file->{name} =~ /\.pod$/i;

    # OR: found an indexed module with the same name
    return $doc
        if $doc and grep { $_->{name} eq $doc } @indexed;

    # OR: found an indexed module with a name
    if ( my ($mod) = grep { defined $_->{name} } @indexed ) {
        return $mod->{name};
    }

    # OR: we have a parsed documentation
    return $doc if defined $doc;

    # OR: found ANY module with a name (better than nothing)
    if ( my ($mod) = grep { defined $_->{name} } @{ $file->{modules} } ) {
        return $mod->{name};
    }

    return undef;
}

1;

__END__

sub import_archive {


        # check for DEPRECATED/DEPRECIATED in abstract of file
        $file->_set_deprecated(1)
            if $deprecated
            or $file_x_deprecated
            or $file->abstract and $file->abstract =~ /DEPRECI?ATED/;

        $file->clear_module if ( $file->is_pod_file );
        $file->documentation;
        $file->suggest;

        log_trace {"reindexing file $file->{path}"};
        $bulk->put($file);
        if ( !$document->has_abstract && $file->abstract ) {
            ( my $module = $document->distribution ) =~ s/-/::/g;
            $document->_set_abstract( $file->abstract );
            $document->put;
        }
    }
    if (@provides) {
        $document->_set_provides( [ uniq sort @provides ] );
        $document->put;
    }
    $bulk->commit;

    if (@release_unauthorized) {
        log_info {
            "release "
                . $document->name
                . " contains unauthorized modules: "
                . join( ",", map { $_->name } @release_unauthorized );
        };
        $document->_set_authorized(0);
        $document->put;
    }

    # update 'first' value
    $document->set_first;
    $document->put;

    # update 'latest' (must be done _after_ last update of the document)
    if ( $self->latest and !$self->queue ) {
        local @ARGV = ( qw< latest --distribution >, $document->distribution );
        MetaCPAN::Script::Runner->run;
    }

    my $contrib_data = $self->get_cpan_author_contributors( $document->author,
        $document->name, $document->distribution );
    $self->update_release_contirbutors($contrib_data);
}


1;

__END__

=head1 SYNOPSIS

 # bin/metacpan ~/cpan/authors/id/A
 # bin/metacpan ~/cpan/authors/id/A/AB/ABRAXXA/DBIx-Class-0.08127.tar.gz
 # bin/metacpan http://cpan.cpantesters.org/authors/id/D/DA/DAGOLDEN/CPAN-Meta-2.110580.tar.gz

 # bin/metacpan ~/cpan --age 24 --latest

=head1 DESCRIPTION

This is the workhorse of MetaCPAN. It accepts a list of folders, files or urls
and indexes the releases. Adding C<--latest> will set the status to C<latest>
for the indexed releases If you are indexing more than one release, running
L<MetaCPAN::Script::Latest> afterwards is probably faster.

C<--age> sets the maximum age of the file in hours. Will be ignored when processing
individual files or an url.

If an url is specified the file is downloaded to C<var/tmp/http/>. This folder is not
cleaned up since L<MetaCPAN::Plack::Source> depends on it to extract the source of
a file. If the archive cannot be find in the cpan mirror, it tries the temporary
folder. After a rsync this folder can be purged.

=cut
