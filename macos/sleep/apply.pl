use strict;
use warnings;
use Fcntl qw(:DEFAULT :mode O_NOFOLLOW O_NONBLOCK :flock);
use POSIX qw(strftime);
use Time::Local qw(timegm);
use JSON::PP qw(decode_json);
# This receiver only accepts the configured local account's request file.
# Config is created by install.py and must remain root-owned and non-writable.
my $base='/var/db/io.github.esp32macremote.sleep';
my $config='/Library/Application Support/ESP32MacRemoteSleep/receiver.json';
sysopen(my $cf,$config,O_RDONLY|O_NOFOLLOW|O_NONBLOCK) or die "Missing receiver configuration\n";
my @cs=stat($cf);
die "Unsafe receiver configuration\n" unless S_ISREG($cs[2]) && $cs[4]==0 && !($cs[2]&0022) && $cs[7]<=4096;
my $json='';sysread($cf,$json,4097);close $cf;
my $settings=decode_json($json);
my $uid=$settings->{uid};my $home=$settings->{home};
die "Invalid receiver configuration\n" unless defined($uid) && $uid =~ /\A[0-9]+\z/ && $uid>=500 && defined($home) && $home =~ m{\A/} && $home !~ /[\r\n\0]/;
my $request="$home/Library/Application Support/MacSleepControl/request.txt";
open(my $lock,'>>',"$base/lock") or die $!;
flock($lock,LOCK_EX|LOCK_NB) or exit 0;
sysopen(my $fh,$request,O_RDONLY|O_NOFOLLOW|O_NONBLOCK) or exit 0;
my @st=stat($fh); exit 0 unless S_ISREG($st[2]) && $st[4]==$uid && $st[7]<=256;
my $raw=''; sysread($fh,$raw,257); close $fh;
exit 0 unless $raw =~ /\A(20|30|50|60|120|180|240|300|sleep)\|([0-9]{9})(?:\|([^\r\n]+))?\s*\z/;
my ($command,$nonce,$issued)=($1,$2,$3);
my $last=''; if(open(my $old,'<',"$base/last-request")){local $/;$last=<$old>;close $old;}
exit 0 if $raw eq $last;
sub write_file {
 my($name,$text,$mode)=@_;
 open(my $out,'>',"$base/$name.tmp") or die $!;binmode $out;print $out $text;close $out or die $!;
 chmod $mode,"$base/$name.tmp";rename "$base/$name.tmp","$base/$name" or die $!;
}
sub status {
 my($message)=@_;
 my $when=strftime('%Y-%m-%d %H:%M:%S %Z',localtime);
 write_file('status.txt',"$message\n执行时间：$when\n请求码：$nonce\n",0644);
}
sub age {
 my($iso)=@_;
 return undef unless defined($iso) && $iso =~ /\A(\d{4})-(\d{2})-(\d{2})T(\d{2}):(\d{2}):(\d{2})(Z|[+-]\d{2}:\d{2})\z/;
 my($y,$m,$d,$h,$mi,$s,$zone)=($1,$2,$3,$4,$5,$6,$7);
 my $epoch=eval {timegm($s,$mi,$h,$d,$m-1,$y)};
 return undef if $@;
 if($zone ne 'Z'){
  $zone =~ /([+-])(\d{2}):(\d{2})/;
  return undef if $2>23 || $3>59;
  $epoch-=($1 eq '+'?1:-1)*($2*3600+$3*60);
 }
 return time-$epoch;
}
if($command eq 'sleep'){
 if(open(my $prev,'<',"$base/last-sleep-request")){local $/;my $old=<$prev>;close $prev;exit 0 if $old eq $raw;}
 write_file('last-sleep-request',$raw,0600);
 # Consume before attempting sleep. A restart or repeated sync must not replay it.
 write_file('last-request',$raw,0600);
 my $age=age($issued);
 if(!defined($age) || $age < -30 || $age > 120){status('睡眠请求已过期或时间无效，未执行。请从手机重新发送。');exit 0;}
 status('Mac 已接收远程睡眠请求，将在约 8 秒后请求系统睡眠。此回执不代表已确认入睡。');
 sleep 8;
 # Recheck expiry after waiting, in case the machine suspended during the delay.
 $age=age($issued);
 if(!defined($age) || $age < -30 || $age > 120){status('睡眠请求已过期，未执行。');exit 0;}
 my $ok=system('/usr/bin/pmset','sleepnow')==0;
 status($ok ? 'Mac 已调用系统睡眠命令。该回执不能独立证明现在仍处于睡眠。' : '远程睡眠失败：系统未接受睡眠命令。');
 exit 0;
}
exit 0 if defined $issued;
my $ok=system('/usr/bin/pmset','-a','sleep',$command)==0;
my $verified=0;
if($ok && open(my $pm,'-|','/usr/bin/pmset','-g','custom')){
 my @values;while(<$pm>){push @values,$1 if /^\s+sleep\s+(\d+)/;}
 close $pm;$verified=@values && !grep {$_ != $command} @values;
}
status($verified ? "Mac 已执行：电脑闲置 $command 分钟后自动睡眠。\n屏幕熄灭时间未修改；软件阻止睡眠时，实际入睡可能推迟。" : '执行失败：未能核实系统睡眠设置，请在 Mac 上检查。');
write_file('last-request',$raw,0600);
