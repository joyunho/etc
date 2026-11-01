# 둥근 기지 설계 생성기

[`../README.md`](../README.md) 5장의 둥근 기지 설계도를 만드는 스크립트입니다.

- `gen_base.py`: 설계를 칸 단위로 만들고 `plan.json`(방, 문, 단계, 동선 거리)을 씁니다. 파이썬 표준 라이브러리만 씁니다.
- `render_png.py`: `plan.json`을 그림(`round-base.png`)으로 그립니다. Pillow가 필요합니다.

```bash
python gen_base.py .
```

```bash
python render_png.py plan.json round-base.png
```

끝에 단계 번호(1~5)를 붙이면 그 단계까지 지은 모습만 그립니다.

```bash
python render_png.py plan.json phase2.png 2
```

`gen_base.py`는 방이 모두 닫혀 있는지, 「중력닻」 자리(4×4)가 모두 창고 바닥인지, 킬박스 포탑이 주머니 안에 있고 기지 벽에서 4칸 넘게 떨어져 있는지 확인하고, 하나라도 어긋나면 멈춥니다.

지름(`R_HALL`, `R_IN`, `R_MID`, `R_OUT`)이나 방 배치(`ROOMS`의 각도 범위)를 바꾸고 다시 돌리면 새 설계가 나옵니다.
