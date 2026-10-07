# Pintos helper subroutines.

use strict;
use warnings;
use POSIX;

# Number of bytes available for the loader at the beginning of the MBR.
# Kernel command-line arguments follow the loader.
our $LOADER_SIZE = 314;

# Partition types.
my (%role2type) = (KERNEL => 0x20,
  FILESYS => 0x21,
  SCRATCH => 0x22,
  SWAP => 0x23);
my (%type2role) = reverse %role2type;

# Order of roles within a given disk.
our (@role_order) = qw (KERNEL FILESYS SCRATCH SWAP);

# Geometry and partition alignment
our (%geometry);
our ($align);

# Partitions.
our (%parts);

# set_part($opt, $arg)
sub set_part {
  my ($opt, $arg) = @_;
  my ($role, $source) = $opt =~ /^([a-z]+)(?:-([a-z]+))?/ or die;

  $role = uc $role;
  $source = 'file' if !defined $source || $source eq '';

  die "can't have two sources for \L$role\E partition"
  if exists $parts{$role};

  do_set_part ($role, $source, $arg);
}

# do_set_part($role, $source, $arg)
sub do_set_part {
  my ($role, $source, $arg) = @_;

  my ($p) = $parts{$role} = {};
  if ($source eq 'file') {
    if (read_mbr ($arg)) {
      print STDERR "warning: $arg looks like a partitioned disk ";
      print STDERR "(did you want --$role-from=$arg or --disk=$arg?)\n"
    }

    $p->{FILE} = $arg;
    $p->{OFFSET} = 0;
    $p->{BYTES} = -s $arg;
  } elsif ($source eq 'from') {
    my (%pt) = read_partition_table ($arg);
    my ($sp) = $pt{$role};
    die "$arg: does not contain \L$role\E partition\n" if !defined $sp;

    $p->{FILE} = $arg;
    $p->{OFFSET} = $sp->{START} * 512;
    $p->{BYTES} = $sp->{SECTORS} * 512;
  } elsif ($source eq 'size') {
    $arg =~ /^\d+(\.\d+)?|\.\d+$/ or die "$arg: not a valid size in MB\n";

    $p->{FILE} = "/dev/zero";
    $p->{OFFSET} = 0;
    $p->{BYTES} = ceil ($arg * 1024 * 1024);
  } else {
    die "unknown source $source to set $role\n";
  }
}

# set_geometry('HEADS,SPT')
sub set_geometry {
  local ($_) = $_[1];
  if ($_ eq 'zip') {
    @geometry{'H', 'S'} = (64, 32);
  } else {
    @geometry{'H', 'S'} = /^(\d+)[,\s]+(\d+)$/
      or die "bad syntax for geometry\n";
    $geometry{H} <= 255 or die "heads limited to 255\n";
    $geometry{S} <= 63 or die "sectors per track limited to 63\n";
  }
}

# set_align('bochs|full|none')
sub set_align {
  $align = $_[1];
  die "unknown alignment type \"$align\"\n"
  if $align ne 'bochs' && $align ne 'full' && $align ne 'none';
}

# assemble_disk(%args)
sub assemble_disk {
  my (%args) = @_;

  my (%geometry) = $args{GEOMETRY} || (H => 16, S => 63);

  my ($align);	# Align partition start, end to cylinder boundary?
  my ($pad);		# Pad end of disk out to cylinder boundary?
  if (!defined ($args{ALIGN}) || $args{ALIGN} eq 'bochs') {
    $align = 0;
    $pad = 1;
  } elsif ($args{ALIGN} eq 'full') {
    $align = 1;
    $pad = 0;
  } elsif ($args{ALIGN} eq 'none') {
    $align = $pad = 0;
  } else {
    die;
  }

  my ($format) = $args{FORMAT} || 'partitioned';
  die if $format ne 'partitioned' && $format ne 'raw';

  # Check that we have partitions to copy in.
  my $part_cnt = grep (defined ($args{$_}), keys %role2type);
  die "must have exactly one partition for raw output\n"
  if $format eq 'raw' && $part_cnt != 1;

  # Calculate the disk size.
  my ($total_sectors) = 0;
  if ($format eq 'partitioned') {
    $total_sectors += $align ? $geometry{S} : 1;
  }
  for my $role (@role_order) {
    my ($p) = $args{$role};
    next if !defined $p;

    die if $p->{DISK};

    my ($bytes) = $p->{BYTES};
    my ($start) = $total_sectors;
    my ($end) = $start + div_round_up ($bytes, 512);
    $end = round_up ($end, cyl_sectors (%geometry)) if $align;

    $p->{DISK} = $args{DISK};
    $p->{START} = $start;
    $p->{SECTORS} = $end - $start;
    $total_sectors = $end;
  }

  # Write the disk.
  my ($disk_fn) = $args{DISK};
  my ($disk) = $args{HANDLE};
  if ($format eq 'partitioned') {
    # Pack loader into MBR.
    my ($loader) = $args{LOADER} || "\xcd\x18";
    my ($mbr) = pack ("a$LOADER_SIZE", $loader);

    $mbr .= make_kernel_command_line (@{$args{ARGS}});

    # Pack partition table into MBR.
    $mbr .= make_partition_table (\%geometry, \%args);

    # Add signature to MBR.
    $mbr .= pack ("v", 0xaa55);

    die if length ($mbr) != 512;
    write_fully ($disk, $disk_fn, $mbr);
    write_zeros ($disk, $disk_fn, 512 * ($geometry{S} - 1)) if $align;
  }
  for my $role (@role_order) {
    my ($p) = $args{$role};
    next if !defined $p;

    my ($source);
    my ($fn) = $p->{FILE};
    open ($source, '<', $fn) or die "$fn: open: $!\n";
    if ($p->{OFFSET}) {
      sysseek ($source, $p->{OFFSET}, 0) == $p->{OFFSET}
        or die "$fn: seek: $!\n";
    }
    copy_file ($source, $fn, $disk, $disk_fn, $p->{BYTES});
    close ($source) or die "$fn: close: $!\n";

    write_zeros ($disk, $disk_fn, $p->{SECTORS} * 512 - $p->{BYTES});
  }
  if ($pad) {
    my ($pad_sectors) = round_up ($total_sectors, cyl_sectors (%geometry));
    write_zeros ($disk, $disk_fn, ($pad_sectors - $total_sectors) * 512);
  }
  close ($disk) or die "$disk: close: $!\n";
}

# make_partition_table({H => heads, S => sectors}, {KERNEL => ..., ...})
sub make_partition_table {
  my ($geometry, $partitions) = @_;
  my ($table) = '';
  for my $role (@role_order) {
    defined (my $p = $partitions->{$role}) or next;

    my $end = $p->{START} + $p->{SECTORS} - 1;
    my $bootable = $role eq 'KERNEL';

    $table .= pack ("C", $bootable ? 0x80 : 0);
    $table .= pack_chs ($p->{START}, $geometry);
    $table .= pack ("C", $role2type{$role});
    $table .= pack_chs($end, $geometry);
    $table .= pack ("V", $p->{START});
    $table .= pack ("V", $p->{SECTORS});
    die if length ($table) % 16;
  }
  return pack ("a64", $table);
}

# make_kernel_command_line(@args)
sub make_kernel_command_line {
  my (@args) = @_;
  my ($args) = join ('', map ("$_\0", @args));
  die "command line exceeds 128 bytes" if length ($args) > 128;
  return pack ("V a128", scalar (@args), $args);
}

# copy_file($from_handle, $from_file_name, $to_handle, $to_file_name, $size)
sub copy_file {
  my ($from_handle, $from_file_name, $to_handle, $to_file_name, $size) = @_;

  while ($size > 0) {
    my ($chunk_size) = 4096;
    $chunk_size = $size if $chunk_size > $size;
    $size -= $chunk_size;

    my ($data) = read_fully ($from_handle, $from_file_name, $chunk_size);
    write_fully ($to_handle, $to_file_name, $data);
  }
}

# read_fully($handle, $file_name, $bytes)
sub read_fully {
  my ($handle, $file_name, $bytes) = @_;
  my ($data);
  my ($read_bytes) = sysread ($handle, $data, $bytes);
  die "$file_name: read: $!\n" if !defined $read_bytes;
  die "$file_name: unexpected end of file\n" if $read_bytes != $bytes;
  return $data;
}

# write_fully($handle, $file_name, $data)
sub write_fully {
  my ($handle, $file_name, $data) = @_;
  my ($written_bytes) = syswrite ($handle, $data);
  die "$file_name: write: $!\n" if !defined $written_bytes;
  die "$file_name: short write\n" if $written_bytes != length $data;
}

sub write_zeros {
  my ($handle, $file_name, $size) = @_;

  while ($size > 0) {
    my ($chunk_size) = 4096;
    $chunk_size = $size if $chunk_size > $size;
    $size -= $chunk_size;

    write_fully ($handle, $file_name, "\0" x $chunk_size);
  }
}

# div_round_up($x,$y)
sub div_round_up {
  my ($x, $y) = @_;
  return int ((ceil ($x) + $y - 1) / $y);
}

# round_up($x, $y)
sub round_up {
  my ($x, $y) = @_;
  return div_round_up ($x, $y) * $y;
}

# cyl_sectors(H => heads, S => sectors)
sub cyl_sectors {
  my (%geometry) = @_;
  return $geometry{H} * $geometry{S};
}

# read_loader($file_name)
sub read_loader {
  my ($name) = @_;
  $name = find_file ("loader.bin") if !defined $name;
  die "Cannot find loader\n" if !defined $name;

  my ($handle);
  open ($handle, '<', $name) or die "$name: open: $!\n";
  -s $handle == $LOADER_SIZE || -s $handle == 512
    or die "$name: must be exactly $LOADER_SIZE or 512 bytes long\n";
  my $loader = read_fully ($handle, $name, $LOADER_SIZE);
  close ($handle) or die "$name: close: $!\n";
  return $loader;
}

# pack_chs($lba, {H => heads, S => sectors})
sub pack_chs {
  my ($lba, $geometry) = @_;
  my ($cyl, $head, $sect) = lba_to_chs ($lba, $geometry);
  return pack ("CCC", $head, $sect | (($cyl >> 2) & 0xc0), $cyl & 0xff);
}

# lba_to_chs($lba, {H => heads, S => sectors})
sub lba_to_chs {
  my ($lba, $geometry) = @_;
  my ($hpc) = $geometry->{H};
  my ($spt) = $geometry->{S};

  use integer;
  my $cyl = $lba / ($hpc * $spt);
  my $temp = $lba % ($hpc * $spt);
  my $head = $temp / $spt;
  my $sect = $temp % $spt + 1;

  if ($cyl <= 1023) {
    return ($cyl, $head, $sect);
  } else {
    return (1023, 254, 63);
  }
}

# read_mbr($file)
sub read_mbr {
  my ($file) = @_;
  my ($retval) = 0;
  open (FILE, '<', $file) or die "$file: open: $!\n";
  if (-s FILE == 0) {
    die "$file: file has zero size\n";
  } elsif (-s FILE >= 512) {
    my ($mbr);
    sysread (FILE, $mbr, 512) == 512 or die "$file: read: $!\n";
    $retval = $mbr if unpack ("v", substr ($mbr, 510)) == 0xaa55;
  }
  close (FILE);
  return $retval;
}

# interpret_partition_table($mbr, $disk)
sub interpret_partition_table {
  my ($mbr, $disk) = @_;
  my (%parts);
  for my $i (0..3) {
    my ($bootable, $valid, $type, $lba_start, $lba_length)
    = unpack ("C X V C x3 V V", substr ($mbr, 446 + 16 * $i, 16));
    next if !$valid;

    (print STDERR "warning: invalid partition entry $i in $disk\n"),
    next if $bootable != 0 && $bootable != 0x80;

    my ($role) = $type2role{$type};
    (printf STDERR "warning: non-Pintos partition type 0x%02x in %s\n",
      $type, $disk),
    next if !defined $role;

    (print STDERR "warning: duplicate \L$role\E partition in $disk\n"),
    next if exists $parts{$role};

    $parts{$role} = {START => $lba_start,
      SECTORS => $lba_length};
  }
  return %parts;
}

# find_file($base_name)
sub find_file {
  my ($base_name) = @_;
  my @locations = (
    $base_name,
    "build/$base_name",
    "../build/$base_name",
    "../../threads/build/$base_name",
    "../../userprog/build/$base_name",
    "../../vm/build/$base_name",
    "../../filesys/build/$base_name"
  );

  if (exists $ENV{PINTOS_HOME}) {
    push @locations, "$ENV{PINTOS_HOME}/src/threads/build/$base_name";
    push @locations, "$ENV{PINTOS_HOME}/src/userprog/build/$base_name";
  }

  foreach my $loc (@locations) {
    return $loc if -e $loc;
  }
  return undef;
}

# read_partition_table($file)
sub read_partition_table {
  my ($file) = @_;
  my ($mbr) = read_mbr ($file);
  die "$file: not a partitioned disk\n" if !$mbr;
  return interpret_partition_table ($mbr, $file);
}

# max(@args)
sub max {
  my ($max) = $_[0];
  foreach (@_[1..$#_]) {
    $max = $_ if $_ > $max;
  }
  return $max;
}

1;
