import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:md3music/core/utils/local_lyric_loader.dart';

List<int> sync(int n)=>[(n>>21)&127,(n>>14)&127,(n>>7)&127,n&127];
List<int> le(int n)=>[(n)&255,(n>>8)&255,(n>>16)&255,(n>>24)&255];
void main(){
  late Directory dir;
  setUp(() async {dir=await Directory.systemTemp.createTemp('md3-lyrics-');});
  tearDown(() async {await dir.delete(recursive:true);});
  const lyric='[00:01.000]<00:01.000>a=b<00:01.500>';
  test('MP3 reads USLT after a large APIC without buffering the image',(){
    final f=File('${dir.path}/large.mp3').openSync(mode:FileMode.write);
    const picture=18*1024*1024;
    final payload=[3,...ascii.encode('und'),0,...utf8.encode(lyric)];
    f.writeFromSync([...ascii.encode('ID3'),4,0,0,...sync(10+picture+10+payload.length)]);
    f.writeFromSync([...ascii.encode('APIC'),...sync(picture),0,0]);
    f.setPositionSync(f.positionSync()+picture);
    f.writeFromSync([...ascii.encode('USLT'),...sync(payload.length),0,0,...payload]);f.closeSync();
    expect(LocalLyricLoader.loadForAudio('${dir.path}/large.mp3'),lyric);
  });
  test('FLAC seeks over picture and padding before full LYRICS comment',(){
    final f=File('${dir.path}/large.flac').openSync(mode:FileMode.write);
    f.writeFromSync(ascii.encode('fLaC'));
    const picture=15*1024*1024;
    f.writeFromSync([6,(picture>>16)&255,(picture>>8)&255,picture&255]);f.setPositionSync(f.positionSync()+picture);
    const padding=2*1024*1024;f.writeFromSync([1,(padding>>16)&255,(padding>>8)&255,padding&255]);f.setPositionSync(f.positionSync()+padding);
    final value=utf8.encode('LYRICS=$lyric');final comment=[...le(0),...le(1),...le(value.length),...value];
    final n=comment.length;f.writeFromSync([0x84,(n>>16)&255,(n>>8)&255,n&255,...comment]);f.closeSync();
    expect(LocalLyricLoader.loadForAudio('${dir.path}/large.flac'),lyric);
  });
}
