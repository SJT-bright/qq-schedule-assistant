# UI Automation bridge. Each submit token is consumed before the sole send key.
# Unknown/incomplete UIA structures fail closed; inspect never modifies QQ.
$ErrorActionPreference='Stop'
[Console]::InputEncoding = [Text.UTF8Encoding]::new($false)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, System.Windows.Forms, System.Drawing
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class QQNative {
 [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
 [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h,out uint p);
 [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
 [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h,int command);
 [DllImport("user32.dll")] public static extern bool SetCursorPos(int x,int y);
 [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h,IntPtr insert,int x,int y,int width,int height,uint flags);
 [StructLayout(LayoutKind.Sequential)] struct INPUT {public uint type;public MOUSE mouse;}
 [StructLayout(LayoutKind.Sequential)] struct MOUSE {public int dx,dy;public uint data,flags,time;public UIntPtr extra;}
 [DllImport("user32.dll", SetLastError=true)] static extern uint SendInput(uint count,INPUT[] inputs,int size);
 public static void Click(){INPUT[] i={new INPUT {type=0,mouse=new MOUSE{flags=2}},new INPUT{type=0,mouse=new MOUSE{flags=4}}};if(SendInput(2,i,Marshal.SizeOf(typeof(INPUT)))!=2)throw new Exception("Pointer input rejected");}
 public static uint ForegroundPID(){uint p;GetWindowThreadProcessId(GetForegroundWindow(),out p);return p;}
}
'@
$script:Bindings=@{}
$script:Submitted=@{}
$script:QQPID=0
function Front {
 if ([QQNative]::ForegroundPID() -ne $script:QQPID) {throw '前台已切换，操作停止；不自动重试'}
}
function ID($e){return ($e.GetRuntimeId() -join '.')}
function Name($e){return $e.Current.Name}
function Type($e){return $e.Current.ControlType.ProgrammaticName.Replace('ControlType.','')}
function Rect($e){return $e.Current.BoundingRectangle}
function Visible($e){$r=Rect $e;return !$e.Current.IsOffscreen -and $r.Width -gt 0 -and $r.Height -gt 0}
function Nodes($root){
 $found=$root.FindAll([System.Windows.Automation.TreeScope]::Descendants,[System.Windows.Automation.Condition]::TrueCondition)
 if($found.Count -gt 6000){throw 'QQ 控件树不完整或过大，停止操作'}
 $list=@($root);for($i=0;$i -lt $found.Count;$i++){$list+=$found.Item($i)};return ,$list
}
function ReadText($e){
 $pat=$null
 if($e.TryGetCurrentPattern([System.Windows.Automation.ValuePattern]::Pattern,[ref]$pat)){return [string]$pat.Current.Value}
 if($e.TryGetCurrentPattern([System.Windows.Automation.TextPattern]::Pattern,[ref]$pat)){return [string]$pat.DocumentRange.GetText(10001)}
 return [string](Name $e)
}
function Parent($e){return [System.Windows.Automation.TreeWalker]::ControlViewWalker.GetParent($e)}
function Belongs($e,$root){$want=ID $root;for($i=0;$i -lt 32 -and $null -ne $e;$i++){if((ID $e)-eq $want){return $true};$e=Parent $e};return $false}
function PointClick($e){
 Front
 if(!(Visible $e)){throw '控件不在可见工作区，未点击'}
 $r=Rect $e;$x=[int]($r.X+$r.Width/2);$y=[int]($r.Y+$r.Height/2)
 $screen=[Windows.Forms.Screen]::AllScreens|Where-Object {$_.WorkingArea.Contains($x,$y)}
 if(!$screen){throw 'QQ 点击位置在屏幕之外，未点击'}
 [void][QQNative]::SetCursorPos($x,$y);Start-Sleep -Milliseconds 180
 $hit=[System.Windows.Automation.AutomationElement]::FromPoint([System.Windows.Point]::new($x,$y))
 if(!(Belongs $hit $e)){throw 'QQ 控件被其他窗口遮挡，未点击'}
 Front;[QQNative]::Click();Start-Sleep -Milliseconds 130
}
function Keys([string]$keys){Front;[Windows.Forms.SendKeys]::SendWait($keys);Start-Sleep -Milliseconds 100;Front}
function WaitFor($block,[int]$ms=6000){$end=[DateTime]::UtcNow.AddMilliseconds($ms);$last=$null;do{Front;try{$r=&$block;if($r){return $r}}catch{$last=$_.Exception.Message};Start-Sleep -Milliseconds 150}while([DateTime]::UtcNow -lt $end);if($last){throw $last};throw 'QQ 控件等待超时，未继续操作'}
function QQWindow {
 $process=Get-Process -Name QQ -ErrorAction SilentlyContinue|Where-Object {$_.MainWindowHandle -ne 0}|Sort-Object StartTime
 if(!$process){throw '请先打开官方 QQ 客户端并登录'}
 $p=@($process)[0];$script:QQPID=$p.Id
 $root=[System.Windows.Automation.AutomationElement]::RootElement
 $all=$root.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty,$p.Id))
 $windows=@();for($i=0;$i -lt $all.Count;$i++){if((Type $all.Item($i))-eq 'Window'){$windows+=$all.Item($i)}}
 $named=@($windows|Where-Object {(Name $_)-eq 'QQ'});$window=if($named.Count){$named[0]}else{$windows|Where-Object {Visible $_}|Select-Object -First 1}
 if(!$window){throw 'QQ 没有可用聊天窗口'}
 $h=[IntPtr]$window.Current.NativeWindowHandle
 [void][QQNative]::ShowWindow($h,9)
 $r=Rect $window;$screens=[Windows.Forms.Screen]::AllScreens;$contained=$screens|Where-Object {$_.WorkingArea.Contains([int]$r.X,[int]$r.Y) -and $_.WorkingArea.Contains([int]($r.Right-2),[int]($r.Bottom-2))}
 if(!$contained){$w=[Windows.Forms.Screen]::PrimaryScreen.WorkingArea;[void][QQNative]::SetWindowPos($h,[IntPtr]::Zero,$w.X+20,$w.Y+20,[Math]::Min([int]$r.Width,$w.Width-40),[Math]::Min([int]$r.Height,$w.Height-40),4)}
 if(![QQNative]::SetForegroundWindow($h)){throw 'QQ 无法置前，未输入内容'}
 Start-Sleep -Milliseconds 300;Front;return $window
}
function FocusSearch($window){
 $r=Rect $window;$fields=@((Nodes $window)|Where-Object {(Type $_)-eq 'Edit' -and (Visible $_) -and (Rect $_).Y -lt $r.Y+140 -and (Rect $_).Height -le 50 -and (Name $_) -match '搜索|Search'})
 if($fields.Count-ne 1){throw '未唯一找到 QQ 顶部搜索框；请检查 QQ 辅助功能控件是否开放'}
 PointClick $fields[0]
 $focused=[System.Windows.Automation.AutomationElement]::FocusedElement
 if(!(Belongs $focused $fields[0])){throw 'QQ 搜索框未获得键盘焦点'}
 return $focused
}
function Context($title){
 Front;$root=[System.Windows.Automation.AutomationElement]::RootElement;$wins=$root.FindAll([System.Windows.Automation.TreeScope]::Children,[System.Windows.Automation.PropertyCondition]::new([System.Windows.Automation.AutomationElement]::ProcessIdProperty,$script:QQPID))
 $candidates=@()
 for($w=0;$w -lt $wins.Count;$w++){
  $win=$wins.Item($w);if(!(Visible $win)){continue};$wr=Rect $win;$nodes=Nodes $win
  $headers=@($nodes|Where-Object {(Type $_)-eq 'Text' -and (Name $_).Trim()-eq $title -and (Visible $_) -and (Rect $_).Y -lt $wr.Y+150 -and (Rect $_).Height-lt 50})
  foreach($header in $headers){
   $hr=Rect $header
   $editors=@($nodes|Where-Object {(Type $_)-in @('Edit','Document') -and (Visible $_) -and (Rect $_).Y-gt $hr.Bottom+50 -and (Rect $_).Height-ge 50 -and (Rect $_).X-ge $hr.X-60 -and $_.Current.AutomationId-match 'ProseMirror|msg-input|qq-msg-editor|chat-input'})
   $lists=@($nodes|Where-Object {(Type $_)-in @('List','Document','Pane') -and (Visible $_) -and $_.Current.AutomationId-match 'message-list|msg-list|chat-msg' -and (Rect $_).Y-gt $hr.Bottom -and (Rect $_).Height-ge 100})
   if($editors.Count-eq 1 -and $lists.Count-eq 1){$editor=$editors[0];$list=$lists[0];$er=Rect $editor;$lr=Rect $list;if($lr.Bottom-le $er.Y+30 -and [Math]::Abs($lr.X-$er.X)-lt 35 -and [Math]::Abs($lr.Width-$er.Width)-lt 50){$candidates+=@{window=$win;header=$header;editor=$editor;list=$list;title=$title}}}
  }
 }
 if($candidates.Count-ne 1){throw 'QQ 会话/消息列/输入框结构未知或不唯一；未填写、未提交。可在设置导出只读诊断。'}
 return $candidates[0]
}
function BindingKey($c){return ((ID $c.window)+'|'+(ID $c.header)+'|'+(ID $c.editor)+'|'+(ID $c.list)+'|'+$c.title)}
function StableContext($title){$one=Context $title;Start-Sleep -Milliseconds 180;$two=Context $title;if((BindingKey $one)-ne (BindingKey $two)){throw '会话或输入框在两拍之间变化，停止操作'};return $two}
function Empty($editor){return (ReadText $editor).Replace([char]0xfffc,'').Trim().Length-eq 0 -and (Images $editor)-eq 0}
function Images($editor){return @((Nodes $editor)|Where-Object {(Type $_)-eq 'Image' -and (Visible $_)}).Count}
function ModalGuard($win){$dialog=@((Nodes $win)|Where-Object {$_.Current.ControlType-eq [System.Windows.Automation.ControlType]::Window -and $_.Current.IsEnabled});if($dialog.Count){throw 'QQ 出现附加窗口，未提交'};if(@((Nodes $win)|Where-Object {(Type $_)-eq 'Button' -and (Name $_)-match '^发送\(\d+\)$|^发送文件$'}).Count){throw 'QQ 出现附件发送确认框，未提交'}}
function MessageSnapshot($c){
 $nodes=Nodes $c.list;$rows=@($nodes|Where-Object {(Type $_)-eq 'ListItem'});if(!$rows.Count){throw 'QQ 消息行结构未知，不能建立发送核验基线'}
 $result=@();foreach($row in $rows){$children=Nodes $row;$sender=@($children|Where-Object {$_.Current.AutomationId-match 'sender|nickname|user-name' -and (Name $_)-match '^(我|本人|你|Me|You)$'});$texts=@($children|Where-Object {$_.Current.AutomationId-match 'msg-content|message-content|text-content'}|ForEach-Object {ReadText $_});$images=@($children|Where-Object {(Type $_)-eq 'Image' -and $_.Current.AutomationId-match 'image-content|msg-image|picture'});$pending=@($children|Where-Object {(Type $_)-eq 'ProgressBar' -or $_.Current.AutomationId-match 'pending|sending|upload|failed|error'});$rid=$row.Current.AutomationId;if(!$rid){throw 'QQ 消息没有稳定编号，不能核验本次发送'};$result+=@{id=$rid;handle=(ID $row);own=($sender.Count-eq 1 -and $rid-match 'self|outgoing|sent-by-me');text=($texts-join "`n");images=$images.Count;pending=($pending.Count-gt 0)}}
 if(@($result|Group-Object id|Where-Object {$_.Count-ne 1}).Count){throw 'QQ 消息编号重复，不能建立基线'}
 return ,$result
}
function PasteText($text){Front;[Windows.Forms.Clipboard]::SetText($text);Keys '^v'}
function Prepare($args){
 $job=$args.job;if($job.channel -and $job.channel-ne 'qq'){throw 'Windows 微信自动发送尚未建立可核验控件档案；该条保留，不自动发送'}
 $window=QQWindow;$search=FocusSearch $window;$originalWindowID=ID $window;$beforeSearch=@((Nodes $window)|Where-Object {(Type $_)-in @('ListItem','MenuItem')}|ForEach-Object {(ID $_)+'|'+(Name $_)}) -join '|';Keys '^a';Keys '{BACKSPACE}';PasteText $job.recipient
 $result=WaitFor {
  $focused=[System.Windows.Automation.AutomationElement]::FocusedElement
  if(!(Belongs $focused $window) -or (ReadText $focused)-ne $job.recipient){throw '原搜索窗口或本次查询值变化，未选择结果'}
  $all=Nodes $window;$wr=Rect $window
  $containers=@($all|Where-Object {$_.Current.AutomationId-match 'search-result|search-list' -or ((Type $_)-in @('List','Pane','Menu') -and (Name $_)-match '^搜索结果$|^群聊搜索结果$|^Search results$')})
  if($containers.Count-ne 1){return $null}
  $rows=@((Nodes $containers[0])|Where-Object {(Type $_)-in @('ListItem','MenuItem') -and (Visible $_) -and (Rect $_).Y-gt (Rect $focused).Bottom -and ((Name $_)-match '群聊|群|Group' -or $_.Current.AutomationId-match 'group')})
  if(!$rows.Count){return $null};$row=$rows|Sort-Object { (Rect $_).Y }|Select-Object -First 1
  $fingerprint=@($rows|ForEach-Object {(ID $_)+'|'+(Name $_)}) -join '|';if($fingerprint-eq $beforeSearch -and (Name $row).IndexOf($job.recipient)-lt 0){return $null};$parts=(Name $row)-split "`n";$name=$parts[0].Trim();if(!$name){return $null};if((Name $row)-match '加入群聊|申请加群|Join'){throw '第一条群结果需要加入，未自动加群'};return @{row=$row;title=$name}
 } 8000
 PointClick $result.row;$title=$result.title;$context=WaitFor {StableContext $title} 6000
 if($args.probe){return @{actualTitle=$title;bindingsIntact=$true;readOnlyDraft=$true}}
 ModalGuard $context.window;if(!(Empty $context.editor)){throw 'QQ 当前群有草稿，未覆盖、未提交'}
 $baseline=MessageSnapshot $context
 PointClick $context.editor
 $clip=[Windows.Forms.Clipboard]::GetDataObject()
 try {
  if($job.text){PasteText $job.text}
  foreach($asset in $job.assets){
   $hash=(Get-FileHash -LiteralPath $asset.path -Algorithm SHA256).Hash.ToLowerInvariant();if($hash-ne $asset.sha256){throw '素材哈希变化，未继续粘贴'}
   if(!$asset.isImage){throw 'Windows 普通文件的提交行为未经核验，未粘贴、未提交'}
   $context=StableContext $title;PointClick $context.editor
   $image=[Drawing.Image]::FromFile($asset.path);try{$bitmap=[Drawing.Bitmap]::new($image);try{Front;[Windows.Forms.Clipboard]::SetImage($bitmap);Keys '^v'}finally{$bitmap.Dispose()}}finally{$image.Dispose()}
   Start-Sleep -Milliseconds 300;ModalGuard $context.window
  }
 } finally {if($clip){[Windows.Forms.Clipboard]::SetDataObject($clip,$true)}else{[Windows.Forms.Clipboard]::Clear()}}
 $ready=WaitFor {$c=StableContext $title;ModalGuard $c.window;if((ReadText $c.editor).Trim()-eq $job.text.Trim() -and (Images $c.editor)-eq $job.assets.Count){return $c};return $null} 6000
 if((BindingKey $context)-ne (BindingKey $ready)){throw '原输入框绑定变化，未提交'}
 $token=[Guid]::NewGuid().ToString();$script:Bindings[$token]=@{context=$ready;key=(BindingKey $ready);baseline=$baseline;text=$job.text;images=$job.assets.Count;pid=$script:QQPID;created=[DateTime]::UtcNow}
 return @{token=$token;actualTitle=$title;bindingsIntact=$true;textMatched=$true;imagesConfirmed=$true}
}
function Submit($args){
 $b=$script:Bindings[$args.token];if(!$b -or $script:Submitted.ContainsKey($args.token)){throw '提交凭据不存在或已消费；禁止重发'}
 $script:Bindings.Remove($args.token);$script:Submitted[$args.token]=$true
 if(([DateTime]::UtcNow-$b.created).TotalSeconds-gt 30){throw '草稿凭据过期，未提交'}
 $script:QQPID=$b.pid;Front;$c=StableContext $b.context.title;ModalGuard $c.window
 if((BindingKey $c)-ne $b.key -or (ReadText $c.editor).Trim()-ne $b.text.Trim() -or (Images $c.editor)-ne $b.images){throw '提交前会话、文字或图片变化，未提交'}
 PointClick $c.editor;$focused=[System.Windows.Automation.AutomationElement]::FocusedElement;if(!(Belongs $focused $c.editor)){throw '输入框未获得焦点，未提交'}
 Front
 # No retry after this line, regardless of the visible result.
 [Windows.Forms.SendKeys]::SendWait('{ENTER}')
 $evidence=$null;$prior=$null;$stable=0;$end=[DateTime]::UtcNow.AddSeconds(12)
 do{Start-Sleep -Milliseconds 450;Front;$fresh=StableContext $b.context.title;if((BindingKey $fresh)-ne $b.key){throw '发送后会话绑定变化，请核对，不自动重发'};$rows=MessageSnapshot $fresh;$before=@($b.baseline|ForEach-Object {$_.id});$tail=@($b.baseline|Select-Object -Last 3|ForEach-Object {$_.id});$positions=@();foreach($id in $tail){$index=[Array]::IndexOf(@($rows|ForEach-Object {$_.id}),$id);if($index-lt 0){throw '发送后旧消息尾锚丢失，保留待核对'};$positions+=$index};for($i=1;$i-lt $positions.Count;$i++){if($positions[$i]-ne $positions[$i-1]+1){throw '消息尾锚不连续，保留待核对'}};$new=@($rows|Select-Object -Skip ($positions[-1]+1)|Where-Object {$_.own -and $_.id-notin $before -and $_.text.Trim()-eq $b.text.Trim() -and $_.images-eq $b.images -and !$_.pending});if($new.Count-eq 1 -and (Empty $fresh.editor)){if($prior-eq $new[0].id){$stable++}else{$prior=$new[0].id;$stable=1};if($stable-ge 2){$evidence=@{messageID=$prior;actualTitle=$b.context.title;textMatched=$true;imagesConfirmed=$true;draftEmpty=$true;stableReads=$stable;oldTail=$tail;rule='windows-uia-v1';serverReceipt=$false};break}}else{$stable=0}}while([DateTime]::UtcNow-lt $end)
 if(!$evidence){throw '发送后本人图文与空草稿未通过双拍核验，请人工核对；不自动重发'}
 return @{verified=$true;evidence=$evidence}
}
function Inspect {
 $ps=Get-Process QQ -ErrorAction SilentlyContinue;$result=@();foreach($p in $ps){if(!$p.MainWindowHandle){continue};$win=[System.Windows.Automation.AutomationElement]::FromHandle($p.MainWindowHandle);$nodes=Nodes $win;$result+=@{pid=$p.Id;title=(Name $win);controls=@($nodes|ForEach-Object {@{type=(Type $_);name=(Name $_);automationId=$_.Current.AutomationId;runtimeId=(ID $_);visible=(Visible $_)}})}};return @{readOnly=$true;windows=$result;platform='windows';profileAccepted=$false}
}
while($null -ne ($line=[Console]::ReadLine())){
 $request=$null
 try{$request=$line|ConvertFrom-Json;$value=switch($request.command){'prepare'{Prepare $request.args};'submit'{Submit $request.args};'inspect'{Inspect};'sound'{$player=[System.Media.SoundPlayer]::new($request.args.file);$player.Load();$player.PlaySync();@{played=$true}};'minimize'{if($request.args.channel-ne 'qq'){throw '未知客户端'};Get-Process QQ -ErrorAction SilentlyContinue|Where-Object {$_.MainWindowHandle-ne 0}|ForEach-Object {[void][QQNative]::ShowWindow($_.MainWindowHandle,6)};@{minimized=$true}};default{throw '未知操作'}};[Console]::WriteLine((@{id=$request.id;ok=$true;result=$value}|ConvertTo-Json -Depth 24 -Compress))}catch{[Console]::WriteLine((@{id=$request.id;ok=$false;error=$_.Exception.Message}|ConvertTo-Json -Depth 12 -Compress))}
}
