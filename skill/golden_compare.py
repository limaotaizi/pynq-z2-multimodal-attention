"""Compare numerical NPZ artifacts without hiding missing keys, shape or dtype drift."""
from pathlib import Path
import argparse,json,hashlib
import numpy as np

def compare(golden,candidate,atol=0.):
 with np.load(golden,allow_pickle=False) as g,np.load(candidate,allow_pickle=False) as c:
  result={'missing':sorted(set(g.files)-set(c.files)),'extra':sorted(set(c.files)-set(g.files)),'arrays':{}}
  for key in sorted(set(g.files)&set(c.files)):
   a,b=g[key],c[key]
   ok=a.shape==b.shape and a.dtype==b.dtype
   if ok:
    ok=bool(np.array_equal(a,b,equal_nan=True)) if a.dtype.kind in 'fciub' and atol==0 else (bool(np.allclose(a,b,atol=atol,rtol=0,equal_nan=True)) if a.dtype.kind in 'fc' else bool(np.array_equal(a,b)))
   result['arrays'][key]={'pass':ok,'golden_shape':list(a.shape),'candidate_shape':list(b.shape),'golden_dtype':str(a.dtype),'candidate_dtype':str(b.dtype),'elements':int(a.size)}
  result['pass']=not result['missing'] and not result['extra'] and all(v['pass'] for v in result['arrays'].values())
 return result
if __name__=='__main__':
 p=argparse.ArgumentParser();p.add_argument('golden');p.add_argument('candidate');p.add_argument('--atol',type=float,default=0.);p.add_argument('--out',required=True);a=p.parse_args()
 if a.atol<0:p.error('atol must be non-negative')
 r=compare(a.golden,a.candidate,a.atol);r['atol']=a.atol;r['files']={str(Path(v).resolve()):hashlib.sha256(Path(v).read_bytes()).hexdigest() for v in [a.golden,a.candidate]};Path(a.out).write_text(json.dumps(r,indent=2),encoding='utf-8');print('PASS' if r['pass'] else 'FAIL');raise SystemExit(0 if r['pass'] else 1)
