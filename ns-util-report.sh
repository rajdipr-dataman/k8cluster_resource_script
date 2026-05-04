#!/usr/bin/env bash
set -euo pipefail

K="${K:-kubectl}"
NS_REGEX="${1:-.*}"
THRESHOLD="${THRESHOLD:-80}"
NOW="$(date '+%Y-%m-%d %H:%M:%S %Z')"

if ! command -v "$K" >/dev/null 2>&1; then
  if [[ "$K" == "k" ]] && command -v kubectl >/dev/null 2>&1; then
    K="kubectl"
  else
    echo "ERROR: command '$K' not found. Use K=kubectl."
    exit 1
  fi
fi

tmp_usage="$(mktemp)"
tmp_quota="$(mktemp)"
trap 'rm -f "$tmp_usage" "$tmp_quota"' EXIT

$K top pods -A --no-headers | awk '
function cpu_to_m(v){ if (v ~ /m$/){sub(/m$/,"",v); return v+0} return (v+0)*1000 }
function mem_to_mi(v,n,u){
  n=v; gsub(/[[:alpha:]]/,"",n); u=v; gsub(/[0-9.]/,"",u)
  if (u=="Ki") return n/1024; if (u=="Mi"||u=="") return n; if (u=="Gi") return n*1024
  if (u=="Ti") return n*1024*1024; if (u=="Pi") return n*1024*1024*1024; return n
}
{ ns=$1; cpu[ns]+=cpu_to_m($3); mem[ns]+=mem_to_mi($4) }
END { for (ns in cpu) printf "%s %.6f %.6f\n", ns, cpu[ns], mem[ns] }
' > "$tmp_usage" || true

$K get resourcequota -A \
  -o go-template='{{range .items}}{{.metadata.namespace}}{{"\t"}}{{index .status.hard "requests.cpu"}}{{"\t"}}{{index .status.hard "requests.memory"}}{{"\n"}}{{end}}' \
| awk '
function cpu_to_m(v){ if (v==""||v=="<no value>"||v=="0") return 0; if (v ~ /m$/){sub(/m$/,"",v); return v+0} return (v+0)*1000 }
function mem_to_mi(v,n,u){
  if (v==""||v=="<no value>"||v=="0") return 0
  n=v; gsub(/[[:alpha:]]/,"",n); u=v; gsub(/[0-9.]/,"",u)
  if (u=="Ki") return n/1024; if (u=="Mi"||u=="") return n; if (u=="Gi") return n*1024
  if (u=="Ti") return n*1024*1024; if (u=="Pi") return n*1024*1024*1024; return n
}
{ ns=$1; cpu[ns]+=cpu_to_m($2); mem[ns]+=mem_to_mi($3) }
END { for (ns in cpu) printf "%s %.6f %.6f\n", ns, cpu[ns], mem[ns] }
' > "$tmp_quota" || true

awk -v ns_re="$NS_REGEX" -v th="$THRESHOLD" -v now="$NOW" '
NR==FNR { u_cpu[$1]=$2; u_mem[$1]=$3; ns[$1]=1; next }
{ q_cpu[$1]+=$2; q_mem[$1]+=$3; ns[$1]=1 }
END {
  print "Generated At:", now
  printf "%-19s %-45s %10s %10s %8s %12s %12s %8s %8s\n",
         "DATE","NAMESPACE","CPU_USED","CPU_HARD","CPU_%","MEM_USED","MEM_HARD","MEM_%","ACTION"

  for (n in ns) {
    if (n !~ ns_re) continue
    uc=u_cpu[n]+0; um=u_mem[n]+0; qc=q_cpu[n]+0; qm=q_mem[n]+0
    cpu_pct=(qc>0)?(uc/qc*100):-1; mem_pct=(qm>0)?(um/qm*100):-1
    action="OK"; if (cpu_pct>=th || mem_pct>=th) action="CHECK"; if (qc==0 && qm==0) action="NO_QUOTA"
    cpu_pct_s=(cpu_pct<0)?"N/A":sprintf("%.1f%%",cpu_pct)
    mem_pct_s=(mem_pct<0)?"N/A":sprintf("%.1f%%",mem_pct)
    line=sprintf("%-19s %-45s %7.2fc %7.2fc %8s %9.2fGi %9.2fGi %8s %8s",
                 now,n,uc/1000,qc/1000,cpu_pct_s,um/1024,qm/1024,mem_pct_s,action)
    out[n]=line
  }

  # print sorted by namespace (requires gawk)
  c=asorti(out, idx)
  for (i=1;i<=c;i++) print out[idx[i]]
}
' "$tmp_usage" "$tmp_quota"
