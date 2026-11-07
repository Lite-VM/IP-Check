#!/usr/bin/env bash
# Interactive read-only network guide. No network/system configuration changes.
set -euo pipefail
for dependency in python3 ip; do
  if ! command -v "$dependency" >/dev/null 2>&1; then
    printf '缺少依赖：%s；请先安装后再运行。\n' "$dependency" >&2
    exit 1
  fi
done
exec python3 - "$@" <<'PY'
import argparse, ipaddress, json, os, shutil, subprocess, sys

parser = argparse.ArgumentParser(description='服务器网络检测与填写引导；不修改网卡、路由、Incus、防火墙或 sysctl。')
parser.add_argument('--interface', help='多网卡时指定父接口，如 ens3；默认依据 IPv6 出口路由选择')
parser.add_argument('--subnet', help='可选：填写服务商明确分配给实例使用的 CIDR；脚本只验证格式，不验证归属')
parser.add_argument('--no-external', action='store_true', help='不向公网服务发送请求，仅检查本地地址/路由')
parser.add_argument('--non-interactive', action='store_true', help='不提问，仅检测')
parser.add_argument('--mode', type=int, choices=[1,2,3,4,5], help='1=IPv4 NAT；2=IPv4/IPv6 NAT；3=IPv4 NAT+独立IPv6；4=IPv6 Only；5=IPv6 NAT')
args = parser.parse_args()
tty = None
if not args.non_interactive:
    try:
        tty_read = open('/dev/tty', 'r')
        tty = open('/dev/tty', 'w', buffering=1)
    except OSError: print('无交互终端，直接输出检测参考。')
def ask(prompt, default='', validate=None):
    if tty is None: return default
    while True:
        tty.write(prompt + (' [' + default + ']' if default else '') + '：')
        tty.flush()
        line = tty_read.readline()
        if not line: return default
        value = line.strip() or default
        if validate is None or validate(value): return value
        tty.write('输入无效，请重新填写。\n')
mode_names = {1:'IPv4 NAT + IPv6（独立子网）',2:'IPv4 NAT + IPv6 NAT',3:'IPv4 NAT',4:'IPv6 Only（独立子网）',5:'IPv6 NAT'}
print('\n=== 服务器网络填写引导 ===\n只读取地址和路由，不修改系统；请在节点宿主机运行。')
menu_modes = {1:3,2:2,3:1,4:4,5:5}
for key in range(1,6): print('  ' + str(key) + '. ' + mode_names[menu_modes[key]])
selection = args.mode or int(ask('请选择网络模式', '1', lambda v:v in ['1','2','3','4','5']))
mode = menu_modes[selection]
if not args.no_external: print('将自动通过 HTTPS 检测公网出口，无需额外确认。')
print('\n第 2 步：读取本机地址与出口路由…')

def run_json(cmd):
    try:
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=8)
        if result.returncode:
            return [], result.stderr.strip()[:200]
        return json.loads(result.stdout or '[]'), ''
    except (OSError, ValueError, subprocess.TimeoutExpired) as exc:
        return [], str(exc)[:200]

def addr(value):
    try:
        result = ipaddress.ip_address(str(value).split('%')[0])
        return result if result.version == 6 else None
    except ValueError:
        return None

def public(value):
    value = addr(value)
    return value is not None and value.is_global and not value.is_multicast

v4_interfaces, _ = run_json(['ip','-j','-4','addr','show'])
v4_lookup, _ = run_json(['ip','-j','-4','route','get','1.1.1.1'])
v4_route = v4_lookup[0] if v4_lookup else {}
v4_addresses = []
for item in v4_interfaces:
    for info in item.get('addr_info', []):
        if info.get('family') == 'inet' and info.get('scope') == 'global':
            try:
                value = ipaddress.IPv4Address(info.get('local',''))
                if not value.is_loopback and not value.is_link_local and not value.is_unspecified and not value.is_multicast:
                    v4_addresses.append((item['ifname'], str(value)))
            except ValueError: pass
valid_v4 = {value for _,value in v4_addresses}
v4_src = v4_route.get('prefsrc') or v4_route.get('src')
if v4_src not in valid_v4:
    v4_src = next((value for interface,value in v4_addresses if interface == v4_route.get('dev')), None)
v4_public, v4_verified = None, False
if v4_src and not args.no_external and shutil.which('curl'):
    try:
        probe = subprocess.run(['curl','-4','--noproxy','*','--interface',v4_src,'--connect-timeout','4','--max-time','8','--fail','--silent','--show-error','https://api.ipify.org'],capture_output=True,text=True,timeout=10)
        value = ipaddress.ip_address(probe.stdout.strip())
        if probe.returncode == 0 and value.version == 4 and value.is_global:
            v4_public, v4_verified = str(value), True
    except (ValueError,OSError,subprocess.TimeoutExpired): pass
if not v4_public and v4_src and ipaddress.IPv4Address(v4_src).is_global: v4_public = v4_src

interfaces, err = run_json(['ip', '-j', '-6', 'addr', 'show'])
if err:
    sys.exit('无法读取 IPv6 地址：' + err)
links = {item['ifname']: item for item in interfaces}
if args.interface and args.interface not in links:
    sys.exit('指定接口不存在：' + args.interface)
defaults, _ = run_json(['ip', '-j', '-6', 'route', 'show', 'default'])
routes, _ = run_json(['ip', '-j', '-6', 'route', 'show'])
# Route lookup only; this ip command does not send packets to the address.
lookup, _ = run_json(['ip', '-j', '-6', 'route', 'get', '2606:4700:4700::1111'])
route = lookup[0] if lookup else {}
iface = args.interface or route.get('dev') or next((r.get('dev') for r in defaults if r.get('dev')), None)
addresses = []
for item in interfaces:
    for item_addr in item.get('addr_info', []):
        if item_addr.get('family') != 'inet6' or item_addr.get('scope') != 'global':
            continue
        flags = set(item_addr.get('flags') or [])
        if any(item_addr.get(k) or k in flags for k in ['tentative','dadfailed','deprecated']):
            continue
        if item_addr.get('valid_life_time') == 0 or not public(item_addr.get('local')):
            continue
        addresses.append({'interface': item['ifname'], 'address': str(addr(item_addr['local'])),
                          'prefix': int(item_addr.get('prefixlen', 128)),
                          'temporary': bool(item_addr.get('temporary') or 'temporary' in flags)})
if not iface and addresses:
    iface = addresses[0]['interface']
local = [a for a in addresses if a['interface'] == iface]
route_src = str(addr(route.get('prefsrc') or route.get('src'))) if route.get('prefsrc') or route.get('src') else ''
local.sort(key=lambda a: (a['temporary'], a['address'] != route_src, a['address']))
selected = local[0] if local else None
source = selected['address'] if selected else None

declared = None
if args.subnet:
    try:
        declared = ipaddress.ip_network(args.subnet, strict=True)
        if declared.version != 6 or declared.prefixlen > 64 or not public(declared.network_address):
            raise ValueError('需要公网 IPv6 网络地址，前缀 /64 或更短；单个 /128 不适用于当前独立 IPv6 表单')
    except ValueError as exc:
        sys.exit('--subnet 无效：' + str(exc))

external, external_error = None, ''
if not args.no_external:
    if not source:
        external_error = '所选接口没有检测到可用公网 IPv6，未发送探测请求'
    elif not shutil.which('curl'):
        external_error = '未安装 curl，已跳过外部连通性检查'
    else:
        # No cookies, tokens or credentials are sent. The service sees the source IP.
        try:
            result = subprocess.run(['curl','-6','--noproxy','*','--interface',source,
                '--connect-timeout','4','--max-time','8','--fail','--silent','--show-error',
                'https://api64.ipify.org'], capture_output=True, text=True, timeout=10)
            value = result.stdout.strip()
            if result.returncode == 0 and public(value):
                external = str(addr(value))
            else:
                external_error = '公网 HTTPS 检查未成功，不能据此认定所有 IPv6 连接均不可用'
        except (OSError, subprocess.TimeoutExpired):
            external_error = '公网 HTTPS 检查失败或超时'

candidates = {}
for item in local:
    if item['prefix'] <= 64:
        network = str(ipaddress.ip_network(item['address'] + '/' + str(item['prefix']), strict=False))
        candidates.setdefault(network, set()).add('本机地址前缀')
for item in routes:
    if item.get('dev') != iface or item.get('gateway') or item.get('type') in ['unreachable','blackhole','prohibit']:
        continue
    try:
        network = ipaddress.ip_network(item.get('dst',''), strict=False)
        if network.version == 6 and 0 < network.prefixlen <= 64 and public(network.network_address):
            candidates.setdefault(str(network), set()).add('本机直连路由')
    except ValueError:
        pass

print('\n=== IPv6 网络检测（只读）===')
print('IPv6 父接口：' + (iface or '未检测到；不要猜填 eth0'))
if iface and not route.get('dev') and not defaults:
    print('  注意：接口仅根据本机地址选出，未检测到正常 IPv6 出口路由。')
print('监听 IPv6：' + (source or '未检测到适合填写的本机公网 IPv6'))
if selected and selected['temporary']:
    print('  注意：仅找到临时地址，可能变化；不建议长期固定为映射监听地址。')
print('公网 IPv6：' + (external or (source + '（本机候选，尚未验证公网出口）' if source else '未检测到')))
if args.no_external:
    print('  未进行公网请求（--no-external）。')
elif external_error:
    print('  ' + external_error)
elif external:
    print('  已通过所选本机地址访问 IPv6 HTTPS 服务；这不证明外部入站端口可达。')
if external and source and external != source:
    print('  注意：公网出口地址与本机地址不同，可能存在 NAT66/上游转换；不可将出口地址直接当作本机监听地址。')
print('IPv6 子网：' + (str(declared) + '（你通过 --subnet 提供，尚未验证服务商授权及上游可达性）' if declared else '无法仅凭本机信息确认可分配子网'))
if candidates:
    print('\n检测到以下候选段（仅供核对，不能直接视为服务商授权地址池）：')
    for network, reasons in sorted(candidates.items()):
        print('  ' + network + '  [' + '、'.join(sorted(reasons)) + ']')
if addresses:
    print('\n本机公网 IPv6 地址：')
    for item in addresses:
        print('  ' + item['interface'] + '  ' + item['address'] + '/' + str(item['prefix']) + ('  临时地址' if item['temporary'] else ''))
print('\n填写说明：')
print('  独立 IPv6 模式：子网必须是服务商允许分配给实例的地址段，当前表单要求 /64 或更短。')
print('  共享 IPv6 NAT：子网与父接口字段通常无需填写；公网/监听 IPv6 参考上面的检测结果。')
print('  纯 IPv4：这些 IPv6 字段不需要填写。')
print('  网卡显示 /64 并不证明整个 /64 可分配；只分配一个 /128 时，不能自行扩大。')
print('  子网检测不覆盖服务商控制台分配、上游路由/NDP策略、入站防火墙或每个实例的实际连通性。')

color_enabled = sys.stdout.isatty() and os.environ.get('TERM') != 'dumb' and 'NO_COLOR' not in os.environ
colors = {'green':'\033[1;32m', 'yellow':'\033[1;33m', 'red':'\033[1;31m', 'cyan':'\033[1;36m'}
def paint(value, color):
    return colors[color] + value + '\033[0m' if color_enabled else value
def field(label, value, color):
    print('  ' + paint(label + '：', 'cyan') + paint(value, color))
print('\n第 3 步：自动生成填写参考，无需逐项输入。')
connection = v4_public or external or source or v4_src or ''
public4 = (v4_public or '') if mode in [1,2,3] else ''
bind4 = (v4_src or 'auto') if mode in [1,2,3] else ''
parent = (iface or '') if mode in [1,4] else ''
public6 = (external or source or '') if mode in [1,2,4,5] else ''
bind6 = (source or 'auto') if mode in [1,2,4,5] else ''
estimated_subnet = str(ipaddress.ip_network(public6 + '/64', strict=False)) if public6 and mode in [1,4] else ''
subnet_input = str(declared) if declared and mode in [1,4] else estimated_subnet
print('\n'+paint('━━ 最终表单填写参考 ━━','cyan'))
field('网络模式',mode_names[mode],'cyan')
field('连接地址',connection or '未检测到，请手动填写','green' if connection else 'red')
field('API 端口','8443（表单默认值，请按实际配置填写）','yellow')
field('公网 IPv4',public4 or ('未检测到' if mode in [1,2,3] else '此模式无需填写'),'green' if public4 and v4_verified and public4==v4_public else 'yellow' if public4 else 'red' if mode in [1,2,3] else 'cyan')
field('监听 IPv4','留空（自动选择）' if bind4=='auto' else bind4 or '此模式无需填写','green' if bind4 else 'cyan')
field('IPv6 子网',subnet_input + ('（命令参数提供；需向服务商确认）' if declared else '（按公网 IPv6 估算 /64；需向服务商确认）') if subnet_input else ('未检测到公网 IPv6，无法估算' if mode in [1,4] else '此模式无需填写'),'yellow' if mode in [1,4] else 'cyan')
field('IPv6 父接口',parent or ('未检测到' if mode in [1,4] else '此模式无需填写'),'green' if parent else 'red' if mode in [1,4] else 'cyan')
field('公网 IPv6',public6 or ('未检测到' if mode in [1,2,4,5] else '此模式无需填写'),'green' if public6 and public6==external else 'yellow' if public6 else 'red' if mode in [1,2,4,5] else 'cyan')
field('监听 IPv6','留空（自动选择）' if bind6=='auto' else bind6 or '此模式无需填写','yellow' if selected and selected['temporary'] else 'green' if bind6 else 'cyan')
print('\n'+paint('绿色：检测到或已选择；黄色：候选/需核实；红色：缺少信息；青色：说明。','cyan'))
print('估算 /64 不代表服务商已分配整个地址段；实际可能仅提供一个 /128，请确认后再用于实例分配。')
print('面板到节点的连通性、上游路由/NDP及入站端口仍需实际确认。')
print('脚本未开放端口、修改配置或创建网络。')
if tty is not None:
    tty.close()
    tty_read.close()
PY
