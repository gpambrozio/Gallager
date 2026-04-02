import sys
E='\033'
ON=E+'(0'    # Switch to DEC Special Graphics
OFF=E+'(B'   # Switch back to ASCII
C=E+'['      # CSI
# DEC chars: l=┌ k=┐ m=└ j=┘ q=─ x=│ w=┬ v=┴ t=├ u=┤ n=┼
# 3 columns: 24 + 26 + 24 = 74 content + 6 junctions/borders = 80
W1=24; W2=26; W3=24
def hline(left, mid, right):
    sys.stdout.write(ON+left+'q'*W1+mid+'q'*W2+mid+'q'*W3+right+OFF+'\n')
def row(c1, c2, c3):
    sys.stdout.write(ON+'x'+OFF+c1.ljust(W1)+ON+'x'+OFF+c2.ljust(W2)+ON+'x'+OFF+c3.ljust(W3)+ON+'x'+OFF+'\n')
sys.stdout.write(C+'2J'+C+'H')
sys.stdout.write(C+'1;33m  Box-Drawing Table Rendering Test'+C+'0m\n\n')
hline('l','w','k')
row(' Name',' Description',' Status')
hline('t','n','u')
row(' Authentication',' User login and token',' Active')
row('   Service',' management system','')
hline('t','n','u')
row(' Database Pool',' Connection pooling for',' Warning: 85%')
row('   Manager',' PostgreSQL with auto-',' capacity')
row('',' scaling and failover','')
hline('t','n','u')
row(' WebSocket Relay',' Real-time bidirectional',' Active')
row('',' message routing between','')
row('',' paired devices','')
hline('t','n','u')
row(' E2E Test Runner',' Automated scenario',' 32/33 passed')
row('',' execution framework','')
hline('m','v','j')
sys.stdout.write('\n'+C+'1;32m  All services operational.'+C+'0m\n')
sys.stdout.flush()
