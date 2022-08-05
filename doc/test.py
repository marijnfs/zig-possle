import math

import random
import time

t = time.time()

n = 0
b = 0
log_thres = 10
blocktime = 10

best_dt = 3 * blocktime

while True:
    b = random.uniform(0, 1)
    dt = blocktime * log_thres /(-math.log(b))
    #dt = blocktime * b / thres
    if dt < best_dt:
        best_dt = dt

    cur_dt = time.time() - t
    if best_dt < cur_dt:
        best_dt = 3 * blocktime
        print(F"block {n} t:{cur_dt}")
        t = time.time()


        n += 1
        
