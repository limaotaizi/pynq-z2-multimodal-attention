import mmap,struct,time
f=open("/dev/mem","r+b",buffering=0)
m=mmap.mmap(f.fileno(),0x1000,mmap.MAP_SHARED,mmap.PROT_READ|mmap.PROT_WRITE,offset=0x40000000)
r=lambda o:struct.unpack_from("<I",m,o)[0]
w=lambda o,v:struct.pack_into("<I",m,o,v&0xffffffff)
print("ID=%08X"%r(0x7C))
def tn():
    for _ in range(8):
        hi=r(0x0C)&0xFFFF
        lo=r(0x08)
        if (r(0x0C)&0xFFFF)==hi: return (hi<<32)|lo
    return -1
w(0,1)
time.sleep(0.2)
a=tn()
t0=time.perf_counter()
time.sleep(2.0)
t1=time.perf_counter()
b=tn()
d=t1-t0
print("TNOW_A=%d TNOW_B=%d DELTA=%d DT=%.5f"%(a,b,b-a,d))
print("CNT_FCLK_MHZ=%.2f"%((b-a)/d/1e6))
w(0,0)
w(0,4)
for i in range(4): w(0x60+4*i,0)
w(0x5C,0)
w(0x60,2000000)
w(0x5C,1)
w(0,1)
time.sleep(2.0)
w(0,0)
n=r(0x14)
print("ENQ=%d"%n)
print("STROBE_FCLK_MHZ=%.2f"%(2.0*n/2.0))
print("FCLK2_DONE")
