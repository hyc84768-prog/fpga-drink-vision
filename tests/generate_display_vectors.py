"""Independent integer image reference for the display-only hardware branch."""
from pathlib import Path
W,H=64,48
root=Path(__file__).resolve().parent
mean=128
valid=False
rows=[]
statistics=[]
for frame in range(10):
    level=frame%3
    image=[]
    for y in range(H):
        for x in range(W):
            if frame==0: value=96
            elif frame==1: value=255 if (x,y)==(32,24) else 96
            elif frame==2: value=32 if x<32 else 220
            elif frame==3: value=36 if y<24 else 210
            elif frame==4: value=96+(x*7+y*13)%7-3
            elif frame==5: value=(x*73+y*31)%256
            elif frame==6: value=40+x*2+(0 if x%16<8 else 40)
            elif frame==7: value=28 if 16<x<47 and 12<y<35 else 90
            elif frame==8: value=100 if 16<x<47 and 12<y<35 else 230
            else: value=16 if 16<x<47 and 12<y<35 else 255
            image.append(value)
    med=[]
    for y in range(H):
        for x in range(W):
            med.append(image[y*W+x] if x<2 or y<2 else
                       sorted(image[(y+dy)*W+x+dx] for dy in range(-2,1) for dx in range(-2,1))[4])
    edges=black=0
    for y in range(H):
        for x in range(W):
            edge,binary=0,255
            if x>=6 and y>=6:
                # Median window is centered one pixel before its trailing
                # coordinate. This second window has a center offset of two.
                a=[[med[(y+dy)*W+x+dx] for dx in range(-4,1)] for dy in range(-4,1)]
                weights=(1,4,6,4,1)
                local=sum(a[j][i]*weights[i]*weights[j] for j in range(5) for i in range(5))//256
                center=a[2][2]
                gx=a[1][3]+2*a[2][3]+a[3][3]-a[1][1]-2*a[2][1]-a[3][1]
                gy=a[3][1]+2*a[3][2]+a[3][3]-a[1][1]-2*a[1][2]-a[1][3]
                edge=255 if abs(gx)+abs(gy)>=4*(12,20,32)[level] else 0
                detail=center-local
                sharp=center+(detail//2 if abs(detail)>=(3,5,8)[level] else 0)
                threshold=max(0,(3*local+mean)//4-(4,8,12)[level])
                binary=0 if sharp<threshold else 255
            edges+=edge==255
            black+=binary==0
            rows.append(f'{image[y*W+x]:02x}{edge:02x}{binary:02x}')
    statistics.append((frame,level,mean,edges,black))
    current=sum(med)//(W*H)
    mean=(3*mean+current)//4 if valid else current
    valid=True
(root/'display_vectors.hex').write_text('\n'.join(rows)+'\n')
print('frame, level, frame mean, edge pixels, dark binary pixels')
for row in statistics: print(*row)
assert statistics[0][3]==0 and statistics[1][3]==0, 'median must remove isolated impulse'
assert statistics[4][3]==0, 'low-amplitude sensor noise must not make edges'
assert statistics[2][3]>0 and statistics[3][3]>0, 'real step edges must remain'
assert statistics[7][4]>0 and statistics[8][4]>0, 'dark object remains visible under different illumination'
