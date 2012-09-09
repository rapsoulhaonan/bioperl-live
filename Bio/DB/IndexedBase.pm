#
# BioPerl module for Bio::DB::IndexedBase
#
# You may distribute this module under the same terms as perl itself
#


=head1 NAME

Bio::DB::IndexedBase - Base class for modules using indexed sequence files

=head1 SYNOPSIS

  use Bio::DB::XXX; # a made-up class that uses Bio::IndexedBase

  # 1/ Bio::SeqIO-style access

  # Index some sequence files
  my $db = Bio::DB::XXX->new('/path/to/file');    # from a single file
  my $db = Bio::DB::XXX->new(['file1', 'file2']); # from multiple files
  my $db = Bio::DB::XXX->new('/path/to/files/');  # from a directory

  # Get IDs of all the sequences in the database
  my @ids = $db->ids;

  # Get a specific sequence
  my $seq = $db->get_Seq_by_id('CHROMOSOME_I');

  # Loop through all sequences
  my $stream = $db->get_Seq_stream;
  while (my $seq = $stream->next_seq) {
    # Do something...
  }


  # 2/ Access via filehandle
  my $fh = Bio::DB::XXX->newFh('/path/to/file');
  while (my $seq = <$fh>) {
    # Do something...
  }

  
  # 3/ Tied-hash access
  tie %sequences, 'Bio::DB::XXX', '/path/to/file';
  print $sequences{'CHROMOSOME_I:1,20000'};

=head1 DESCRIPTION

Bio::DB::IndexedBase provides a base class for modules that want to index
and read sequence files and provides persistent, random access to each sequence
entry, without bringing the entire file into memory. Bio::DB::Fasta and
Bio::DB::Qual both use Bio::DB::IndexedBase.

When you initialize the module, you point it at a single file, several files, or
a directory of files. The first time it is run, the module generates an index
of the content of the files using the AnyDBM_File module (BerkeleyDB preferred,
followed by GDBM_File, NDBM_File, and SDBM_File). Subsequently, it uses the
index file to find the sequence file and offset for any requested sequence. If
one of the source files is updated, the module reindexes just that one file. You
can also force reindexing manually at any time. For improved performance, the
module keeps a cache of open filehandles, closing less-recently used ones when
the cache is full.

Entries may have any line length up to 65,536 characters, and different line
lengths are allowed in the same file.  However, within a sequence entry, all
lines must be the same length except for the last. An error will be thrown if
this is not the case!

This module was developed for use with the C. elegans and human genomes, and has
been tested with sequence segments as large as 20 megabases. Indexing the C.
elegans genome (100 megabases of genomic sequence plus 100,000 ESTs) takes ~5
minutes on my 300 MHz pentium laptop. On the same system, average access time
for any 200-mer within the C. elegans genome was E<lt>0.02s.

=head1 DATABASE CREATION AND INDEXING

The two constructors for this class are new() and newFh(). The former creates a
Bio::DB::IndexedBase object which is accessed via method calls. The latter
creates a tied filehandle which can be used Bio::SeqIO style to fetch sequence
objects in a stream fashion. There is also a tied hash interface.

=over

=item $db = Bio::DB::IndexedBase-E<gt>new($path [,%options])

Create a new Bio::DB::IndexedBase object from the files designated by $path
$path may be a single file, an arrayref of files, or a directory containing
such files.

After the database is created, you can use methods like ids() and get_Seq_by_id()
to retrieve sequence objects.

=item $fh = Bio::DB::IndexedBase-E<gt>newFh($path [,%options])

Create a tied filehandle opened on a Bio::DB::IndexedBase object. Reading
from this filehandle with E<lt>E<gt> will return a stream of sequence objects,
Bio::SeqIO style. The path and the options should be specified as for new().

=item $obj = tie %db,'Bio::DB::IndexedBase', '/path/to/file' [,@args]

Create a tied-hash by tieing %db to Bio::DB::IndexedBase using the indicated
path to the files. The optional @args list is the same set used by new(). If 
successful, tie() returns the tied object, undef otherwise.

Once tied, you can use the hash to retrieve an individual sequence by
its ID, like this:

  my $seq = $db{CHROMOSOME_I};

The keys() and values() functions will return the sequence IDs and
their sequences, respectively.  In addition, each() can be used to
iterate over the entire data set:

 while (my ($id,$sequence) = each %db) {
    print "$id => $sequence\n";
 }


When dealing with very large sequences, you can avoid bringing them
into memory by calling each() in a scalar context.  This returns the
key only.  You can then use tied(%db) to recover the Bio::DB::IndexedBase
object and call its methods.

 while (my $id = each %db) {
    print "$id: $db{$sequence:1,100}\n";
    print "$id: ".tied(%db)->length($id)."\n";
 }

In addition, you may invoke the FIRSTKEY and NEXTKEY tied hash methods directly
to retrieve the first and next ID in the database, respectively. This allows to
write the following iterative loop using just the object-oriented interface:

 my $db = Bio::DB::IndexedBase->new('/path/to/file');
 for (my $id=$db->FIRSTKEY; $id; $id=$db->NEXTKEY($id)) {
    # do something with sequence
 }

=back

=head1 BUGS

When a sequence is deleted from one of the files, this deletion is not detected
by the module and removed from the index. As a result, a "ghost" entry will
remain in the index and will return garbage results if accessed.

Currently, the only way to accommodate sequence removal is to rebuild the entire
index, either by deleting it manually, or by passing -reindex=E<gt>1 to new()
when initializing the module.


=head1 SEE ALSO

L<DB_File>

L<Bio::DB::Fasta>

L<Bio::DB::Qual>

=head1 AUTHOR

Lincoln Stein E<lt>lstein@cshl.orgE<gt>.

Copyright (c) 2001 Cold Spring Harbor Laboratory.

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself.  See DISCLAIMER.txt for
disclaimers of warranty.

=head1 APPENDIX

The rest of the documentation details each of the object
methods. Internal methods are usually preceded with a _

=cut


package Bio::DB::IndexedBase;

BEGIN {
  @AnyDBM_File::ISA = qw(DB_File GDBM_File NDBM_File SDBM_File)
}

use strict;
use IO::File;
use AnyDBM_File;
use Fcntl;
use File::Spec;
use File::Basename qw(dirname);

use base qw(Bio::Root::Root);

use constant STRUCT    =>'NNnnCa*'; # 32-bit file offset and seq length
use constant STRUCTBIG =>'QQnnCa*'; # 64-bit

use constant NA        => 0;
use constant DNA       => 1;
use constant RNA       => 2;
use constant PROTEIN   => 3;

use constant DIE_ON_MISSMATCHED_LINES => 1;
# you can avoid dying if you want but you may get incorrect results

my ($caller, @fileno2path, %filepath2no);


=head2 new

 Title   : new
 Usage   : my $db = Bio::DB::IndexedBase->new($path, -reindex => 1);
 Function: Initialize a new database object
 Returns : A Bio::DB::IndexedBase object
 Args    : A single file, or path to dir, or arrayref of files
           Optional arguments:

 Option        Description                                         Default
 -----------   -----------                                         -------

 -glob         Glob expression to search for files in directories  *

 -makeid       A code subroutine for transforming IDs              None

 -maxopen      Maximum size of filehandle cache                    32

 -debug        Turn on status messages                             0

 -reindex      Force the index to be rebuilt                       0

 -dbmargs      Additional arguments to pass to the DBM routine     None

 -index_name   Name of the file that will hold the indices

 -clean        Remove the index file when finished                 0

The -dbmargs option can be used to control the format of the index. For example,
you can pass $DB_BTREE to this argument so as to force the IDs to be sorted and
retrieved alphabetically. Note that you must use the same arguments every time
you open the index!

The -makeid option gives you a chance to modify sequence IDs during indexing.
For example, you may wish to extract a portion of the gi|gb|abc|xyz nonsense
that GenBank Fasta files use. The original header line can be recovered later.
The option value should be a code reference that takes a scalar argument and
returns a scalar result, like this:

  $db = Bio::DB::IndexedBase->new('file.fa', -makeid => \&make_my_id);

  sub make_my_id {
      my $description_line = shift;
      # get a different id from the header, e.g.
      $description_line =~ /(\S+)$/;
      return $1;
  }

make_my_id() will be called with the full header line, e.g. a Fasta line would
include the "E<gt>", the ID and the description:

 >A12345.3 Predicted C. elegans protein egl-2

The -makeid option is ignored after the index is constructed.

=cut

sub new {
  my ($class, $path, %opts) = @_;

  # Determine which module called IndexedBase: Bio::DB::Fasta? Bio::DB::Qual?
  $caller = (caller(0))[0];

  my $self = bless {
    debug      => $opts{-debug},
    makeid     => $opts{-makeid},
    glob       => $opts{-glob}    || '*',
    maxopen    => $opts{-maxopen} || 32,
    clean      => $opts{-clean}   || 0,
    dbmargs    => $opts{-dbmargs} || undef,
    fhcache    => {},
    cacheseq   => {},
    curopen    => 0,
    openseq    => 1,
    dirname    => undef,
    offsets    => undef,
    index_name => $opts{-index_name},
    obj_class  => eval '$'.$caller.'::obj_class',
  }, $class;

  my ($offsets, $dirname);
  my $ref = ref $path || '';
  if ( $ref eq 'ARRAY' ) {
    $offsets = $self->index_files($path, $opts{-reindex});
    require Cwd;
    $dirname = Cwd::getcwd();
  } else {
    if (-d $path) {
      # because Win32 glob() is broken with respect to long file names
      # that contain whitespace.
      $path = Win32::GetShortPathName($path)
        if $^O =~ /^MSWin/i && eval 'use Win32; 1';
      $offsets = $self->index_dir($path, $opts{-reindex});
      $dirname = $path;
    } elsif (-f _) {
      $offsets = $self->index_file($path, $opts{-reindex});
      $dirname = dirname($path);
    } else {
      $self->throw( "$path: Invalid file or dirname");
    }
  }
  @{$self}{qw(dirname offsets)} = ($dirname,$offsets);

  return $self;
}


=head2 newFh

 Title   : newFh
 Usage   : my $fh = Bio::DB::IndexedBase->newFh('/path/to/files/', %options);
 Function: Index and get a new Fh for a single file, several files or a directory
 Returns : Filehandle object
 Args    : Same as new()

=cut

sub newFh {
    my ($class, @args) = @_;
    my $self = $class->new(@args);
    require Symbol;
    my $fh = Symbol::gensym;
    tie $$fh, 'Bio::DB::Indexed::Stream', $self
        or $self->throw("Could not tie filehandle: $!");
    return $fh;
}


=head2 dbmargs

 Title   : dbmargs
 Usage   : my @args = $db->dbmargs;
 Function: Get stored dbm arguments
 Returns : Array
 Args    : None

=cut

sub dbmargs {
    my $self = shift;
    my $args = $self->{dbmargs} or return;
    return ref($args) eq 'ARRAY' ? @$args : $args;
}


=head2 index_dir

 Title   : index_dir
 Usage   : $db->index_dir($dir);
 Function: Index the files that match -glob in the given directory
 Returns : Hashref of offsets
 Args    : Dirname
           Boolean to force a reindexing the directory

=cut

sub index_dir {
    my ($self, $dir, $force_reindex) = @_;
    my @files = glob( File::Spec->catfile($dir, $self->{glob}) );
    $self->throw("No suitable files found in $dir") if scalar @files == 0;
    $self->{index_name} ||= File::Spec->catfile($dir, 'directory.index');
    my $offsets = $self->_index_files(\@files, $force_reindex);
    return $offsets;
}


=head2 get_all_ids

 Title   : get_all_ids, ids
 Usage   : my @ids = $db->get_all_ids;
 Function: Get the IDs stored in all indexes
 Returns : List of ids
 Args    : None

=cut

sub get_all_ids  {
    return keys %{shift->{offsets}};
}

*ids = \&get_all_ids;


=head2 index_file

 Title   : index_file
 Usage   : $db->index_file($filename);
 Function: Index the given file
 Returns : Hashref of offsets
 Args    : Filename
           Boolean to force reindexing the file

=cut

sub index_file {
    my ($self, $file, $force_reindex) = @_;
    $self->{index_name} ||= "$file.index";
    my $offsets = $self->_index_files([$file], $force_reindex);
    return $offsets;
}


=head2 index_files

 Title   : index_files
 Usage   : $db->index_files(\@files);
 Function: Index the given files
 Returns : Hashref of offsets
 Args    : Arrayref of filenames
           Boolean to force reindexing the files

=cut

sub index_files {
    my ($self, $files, $force_reindex) = @_;
    my @paths = map { File::Spec->rel2abs($_) } @$files;
    require Digest::MD5;
    my $digest = Digest::MD5::md5_hex( join('', sort @paths) );
    $self->{index_name} ||= "fileset_$digest.index"; # unique name for the given files
    my $offsets = $self->_index_files($files, $force_reindex);
    return $offsets;
}


=head2 index_name

 Title   : index_name
 Usage   : my $indexname = $db->index_name($path);
 Function: Get the full name of the index file
 Returns : String
 Args    : None

=cut

sub index_name {
    return shift->{index_name};
}


=head2 path

 Title   : path
 Usage   : my $path = $db->path($path);
 Function: When a simple file or a directory of files is indexed, this returns
           the file directory. When indexing an arbitrary list of files, the
           return value is the path of the current working directory.
 Returns : String
 Args    : None

=cut

sub path {
    return shift->{dirname};
}


=head2 get_Seq_stream

 Title   : get_Seq_stream
 Usage   : my $stream = $db->get_Seq_stream();
 Function: Get a SeqIO-like stream of sequence objects. The stream supports a
           single method, next_seq(). Each call to next_seq() returns a new
           PrimarySeqI compliant sequence object, until no more sequences remain.
 Returns : A Bio::DB::Indexed::Stream object
 Args    : None

=cut

sub get_Seq_stream {
  my $self = shift;
  return Bio::DB::Indexed::Stream->new($self);
}

*get_PrimarySeq_stream = \&get_Seq_stream;


=head2 get_Seq_by_id

 Title   : get_Seq_by_id, get_Seq_by_acc, get_Seq_by_primary_id
 Usage   : my $seq = $db->get_Seq_by_id($id);
 Function: Given an ID, fetch the corresponding sequence from the database.
           This is a Bio::DB::RandomAccessI method implementation.
 Returns : A sequence object
 Args    : ID

=cut

sub get_Seq_by_id {
  my ($self, $id) = @_;
  $self->throw('Need to provide a sequence ID') if not defined $id;
  return if not exists $self->{offsets}{$id};
  return $self->{obj_class}->new($self, $id);
}

*get_seq_by_primary_id = *get_Seq_by_acc = \&get_Seq_by_id;


=head2 _calculate_offsets

 Title   : _calculate_offsets
 Usage   : $db->_calculate_offsets($filename, $offsets);
 Function: This method calculates the sequence offsets in a file based on ID and
           should be implemented by classes that use Bio::DB::IndexedBase. 
 Returns : Hash of offsets
 Args    : File to process
           Hashref of file offsets keyed by IDs.

=cut

sub _calculate_offsets {
   my $self = shift;
   $self->throw_not_implemented();
}


sub _index_files {
    # Do the indexing of the given files using the index file on record
    my ($self, $files, $force_reindex) = @_;

    $self->_set_pack_method( @$files );

    # get name of index file
    my $index = $self->index_name;

    # if caller has requested reindexing, unlink the index file.
    unlink $index if $force_reindex;

    # get the modification time of the index
    my $indextime = (stat $index)[9] || 0;

    # list recently updated files
    my $modtime = 0;
    my @updated;
    for my $file (@$files) {
        my $m = (stat $file)[9] || 0;
        if ($m > $modtime) {
           $modtime = $m;
        }
        if ($m > $indextime) {
           push @updated, $file;
        }
    }

    my $reindex      = $force_reindex || (scalar @updated > 0);
    $self->{offsets} = $self->_open_index($index, $reindex) or return;

    if ($reindex) {
        # reindex contents of changed files
        $self->{indexing} = $index;

        my $method = \&{$caller.'::_calculate_offsets'};

        for my $file (@updated) {
            &$method($self, $file, $self->{offsets});
        }
        delete $self->{indexing};
    }

    # closing and reopening might help corrupted index file problem on Windows
    $self->_close_index($self->{offsets});

    return $self->{offsets} = $self->_open_index($index);
}


sub _open_index {
    # Open index file in read-only or write mode
    my ($self, $index_file, $write) = @_;
    my %offsets;
    my $flags = $write ? O_CREAT|O_RDWR : O_RDONLY;
    my @dbmargs = $self->dbmargs;
    tie %offsets, 'AnyDBM_File', $index_file, $flags, 0644, @dbmargs 
        or $self->throw( "Could not open index file $index_file: $!");
    return \%offsets;
}


sub _close_index {
    # Close index file
    my ($self, $index) = @_;
    untie %$index;
    return 1;
}


sub _parse_compound_id {
    # Handle compound IDs:
    #     $db->seq($id)
    #     $db->seq($id, $start, $stop)
    #     $db->seq("$id:$start,$stop")
    #     $db->seq("$id:$start..$stop")
    #     $db->seq("$id:$start-$stop")
    my ($self, $id, $start, $stop) = @_;

    if ( (not defined $start) &&
         (not defined $stop ) &&
         ($id =~ /^(.+):([\d_]+)(?:,|-|\.\.)([\d_]+)$/) ) {
        # Start and stop not provided and ID looks like a compound ID
        ($id, $start, $stop) = ($1, $2, $3);
        $start =~ s/_//g;
        $stop  =~ s/_//g;
    }
    $start ||= 1;
    $stop  ||= $self->length($id);

    my $strand = 1;
    if ($start > $stop) {
        ($start, $stop) = ($stop, $start);
        $strand = -1;
    }

    return $id, $start, $stop, $strand;
}


sub _type {
  # Determine the molecular type of the given a sequence string: dna, rna or protein
  my ($self, $string) = @_;
  return $string =~ m/^[gatcnGATCN*-]+$/   ? DNA
         : $string =~ m/^[gaucnGAUCN*-]+$/ ? RNA
         : PROTEIN;
}


sub _check_linelength {
    # Check that the line length is valid. Generate an error otherwise.
    my ($self, $linelength) = @_;
    return if not defined $linelength;
    $self->throw(
        "Each line of the qual file must be less than 65,536 characters. Line ".
        "$. is $linelength chars."
    ) if $linelength > 65535;
}


sub _caloffset {
    # Get the offset of the n-th residue of the sequence with the given id
    # and termination length (tl)
    my ($self, $id, $n, $tl) = @_;
    $n--;
    my ($offset, $seqlength, $linelength, $firstline, $file)
        = &{$self->{unpackmeth}}($self->{offsets}{$id});
    $n = 0            if $n < 0;
    $n = $seqlength-1 if $n >= $seqlength;
    return $offset + $linelength * int($n/($linelength-$tl)) + $n % ($linelength-$tl);
}


sub _fh {
    # Given a sequence ID, return the filehandle on which to find this sequence
    my ($self, $id) = @_;
    $self->throw('Need to provide a sequence ID') if not defined $id;
    my $file = $self->file($id) or return;
    return $self->_fhcache( File::Spec->catfile($self->{dirname}, $file) ) or
        $self->throw( "Can't open file $file");
}


sub _fhcache {
    my ($self, $path) = @_;
    if (!$self->{fhcache}{$path}) {
        if ($self->{curopen} >= $self->{maxopen}) {
            my @lru = sort {$self->{cacheseq}{$a} <=> $self->{cacheseq}{$b};}
                keys %{$self->{fhcache}};
            splice(@lru, $self->{maxopen} / 3);
            $self->{curopen} -= @lru;
            for (@lru) {
                delete $self->{fhcache}{$_};
            }
        }
        $self->{fhcache}{$path} = IO::File->new($path) || return;
        binmode $self->{fhcache}{$path};
        $self->{curopen}++;
    }
    $self->{cacheseq}{$path}++;
    return $self->{fhcache}{$path};
}


sub _fileno2path {
    my ($self, $fileno) = @_;
    return $fileno2path[$fileno];
}


sub _path2fileno {
    my ($self, $path) = @_;
    if ( not exists $filepath2no{$path} ) {
        my $fileno = ($filepath2no{$path} = 0+ $self->{fileno}++);
        $fileno2path[$fileno] = $path;
    }
    return $filepath2no{$path};
}


sub _pack {
    return pack STRUCT, @_;
}


sub _packBig {
    return pack STRUCTBIG, @_;
}


sub _unpack {
    return unpack STRUCT, shift;
}


sub _unpackBig {
    return unpack STRUCTBIG, shift;
}


sub _set_pack_method {
    # Determine whether to use 32 or 64 bit integers for the given files.
    my $self = shift;
    # Find the maximum file size:
    my ($maxsize) = sort { $b <=> $a } map { -s $_ } @_;
    my $fourGB    = (2 ** 32) - 1;

    if ($maxsize > $fourGB) {
        # At least one file exceeds 4Gb - we will need to use 64 bit ints
        $self->{packmeth}   = \&_packBig;
        $self->{unpackmeth} = \&_unpackBig;
    } else {
        $self->{packmeth}   = \&_pack;
        $self->{unpackmeth} = \&_unpack;
    }
    return 1;
}


#-------------------------------------------------------------
# Tied hash logic
#

sub TIEHASH {
    return shift->new(@_);
}


sub FETCH {
    return shift->subseq(@_);
}


sub STORE {
    shift->throw("Read-only database");
}


sub DELETE {
    shift->throw("Read-only database");
}


sub CLEAR {
    shift->throw("Read-only database");
}


sub EXISTS {
    return defined shift->offset(@_);
}


sub FIRSTKEY {
    return tied(%{shift->{offsets}})->FIRSTKEY(@_);
}


sub NEXTKEY {
    return tied(%{shift->{offsets}})->NEXTKEY(@_);
}


sub DESTROY {
    my $self = shift;
    if ( $self->{clean} || $self->{indexing} ) {
      # Indexing aborted or cleaning requested. Delete the index file.
      unlink $self->{index_name};
    }
    return 1;
}


#-------------------------------------------------------------
# stream-based access to the database
#

package Bio::DB::Indexed::Stream;
use base qw(Tie::Handle Bio::DB::SeqI);


sub new {
    my ($class, $db) = @_;
    my $key = $db->FIRSTKEY;
    return bless {
        db  => $db,
        key => $key
    }, $class;
}

sub next_seq {
    my $self = shift;
    my ($key, $db) = @{$self}{'key', 'db'};
    return if not defined $key;
    my $value = $db->get_Seq_by_id($key);
    $self->{key} = $db->NEXTKEY($key);
    return $value;
}

sub TIEHANDLE {
    my ($class, $db) = @_;
    return $class->new($db);
}

sub READLINE {
    my $self = shift;
    return $self->next_seq;
}


1;