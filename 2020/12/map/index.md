# 常见的数据结构--map


很多的业务场景都会用到map，在其他语言可能成为set/集合等，主要就是`key:value`格式。

```text
// A map is just a hash table. The data is arranged
// into an array of buckets. Each bucket contains up to
// 8 key/elem pairs. The low-order bits of the hash are
// used to select a bucket. Each bucket contains a few
// high-order bits of each hash to distinguish the entries
// within a single bucket.
//
// If more than 8 keys hash to a bucket, we chain on
// extra buckets.
//
// When the hashtable grows, we allocate a new array
// of buckets twice as big. Buckets are incrementally
// copied from the old bucket array to the new bucket array.
```
map内部实现是一个哈希表，内部维护了一个buckets数组，每个buckets最多包含8个键值对，
每个key的哈希值的低位是buckets的索引，高位用来区分。
如果超过8个元素，变会使用额外的buckets链接。
当哈希表扩容时，会分配一个比当前大两倍的空间，旧buckets里的数据会递增地拷贝到新buckets中。

## 内部数据结构
```go
type hmap struct {
	count     int // 当前大小
	flags     uint8
	B         uint8  // 能容纳 2^B buckets
	noverflow uint16 // 溢出 buckets 的数量
	hash0     uint32 // hash seed
	buckets    unsafe.Pointer //  2^B Buckets 数组指针. may be nil if count==0.
	oldbuckets unsafe.Pointer // 扩容时的buckets数组
	nevacuate  uintptr        // rehash 的进度
	extra *mapextra // optional fields
}
```

map底层维护了一个hmap的结构，hmap维护了一个buckets数组，buckets数组的元素是一个bmap结构，真正的数据放到bmap中。
```go
type bmap struct {
	// tophash generally contains the top byte of the hash value
	// for each key in this bucket. If tophash[0] < minTopHash,
	// tophash[0] is a bucket evacuation state instead.
	tophash [bucketCnt]uint8 // bucketCnt = 8
}
```
bmap是一个长度为8的数组，map的key经过hash会放到bmap中，bmap只存hash value的top byte，uint8表示hash value的高8位，
这样的好处是每次查找key时不要比较key的每个字符，从而增加查找效率。

## 创建map
```go
func makemap(t *maptype, hint int, h *hmap) *hmap {
	mem, overflow := math.MulUintptr(uintptr(hint), t.bucket.size)
	if overflow || mem > maxAlloc {
		hint = 0
	}

	// initialize Hmap
	if h == nil {
		h = new(hmap)
	}
    // 随机种子，使得每个key在不同的map中生成的哈希值不同
	h.hash0 = fastrand()

	// 找到合适的B使得map的装载因子在正常范围内
	B := uint8(0)
	for overLoadFactor(hint, B) {
		B++
	}
	h.B = B

	// 初始化 hash table
	// 如果 B == 0, buckets 会在赋值后分配
	// 如果长度比较大，分配内存的时间会变长
	if h.B != 0 {
		var nextOverflow *bmap
		h.buckets, nextOverflow = makeBucketArray(t, h.B, nil)
		if nextOverflow != nil {
			h.extra = new(mapextra)
			h.extra.nextOverflow = nextOverflow
		}
	}

	return h
}
```
过程：
- 创建hmap，并初始化
- 获取一个随机种子，保证同一个key在不同map中的哈希值不同（安全考量）
- 计算初始桶的大小
- 如果初始桶大小不为0，则创建桶，有必要还需创建溢出桶结构

## 查找map
```go
func mapaccess1(t *maptype, h *hmap, key unsafe.Pointer) unsafe.Pointer {
	if raceenabled && h != nil {
		callerpc := getcallerpc()
		pc := funcPC(mapaccess1)
		racereadpc(unsafe.Pointer(h), callerpc, pc)
		raceReadObjectPC(t.key, key, callerpc, pc)
	}
	if msanenabled && h != nil {
		msanread(key, t.key.size)
	}
    
    // 如果空值，返回value类型的零值
	if h == nil || h.count == 0 {
		if t.hashMightPanic() {
			t.hasher(key, 0) // see issue 23734
		}
		return unsafe.Pointer(&zeroVal[0])
	}
    // 并发读写冲突
	if h.flags&hashWriting != 0 {
		throw("concurrent map read and map write")
	}
    // 计算hash值
	hash := t.hasher(key, uintptr(h.hash0))
    // 计算B的掩码，1<<B-1
	m := bucketMask(h.B)
    // b是当前key对应的bucket的地址
	b := (*bmap)(add(h.buckets, (hash&m)*uintptr(t.bucketsize)))
    // oldbuckets不为nil，发生扩容
	if c := h.oldbuckets; c != nil {
		if !h.sameSizeGrow() {
			// There used to be half as many buckets; mask down one more power of two.
			m >>= 1
		}
        // 求出key在老map中的buckets的位置
		oldb := (*bmap)(add(c, (hash&m)*uintptr(t.bucketsize)))
		if !evacuated(oldb) {
			b = oldb
		}
	}
    // 计算高8位
	top := tophash(hash)
// 进入bucket的二层循环找到对应的键值对
bucketloop:
    // 遍历bucket及overflow链表
	for ; b != nil; b = b.overflow(t) {
        // 遍历bucket的8个slot
		for i := uintptr(0); i < bucketCnt; i++ {
			if b.tophash[i] != top { // tophash不匹配
                // 标识当前bucket剩下的slot都是empty
				if b.tophash[i] == emptyRest {
					break bucketloop
				}
				continue
			}
            // 获取bucket的key
			k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
			if t.indirectkey() {
				k = *((*unsafe.Pointer)(k))
			}
			if t.key.equal(key, k) {
                // 定位到value的位置
				e := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
				if t.indirectelem() {
					e = *((*unsafe.Pointer)(e))
				}
				return e
			}
		}
	}
	return unsafe.Pointer(&zeroVal[0])
}
```
过程：
- 读写检查
- 计算key的哈希值，并根据哈希值计算key所在桶的位置
- 计算tophash值，便于快速查找
- 遍历桶链上的每个桶，并依次遍历桶内元素
- 先比较tophash，如果tophash不同，比较下一个，如果相同，再比较key值是否相等
- 如果key相等，计算value的地址，并去除value，直接返回
- 若key不等，比较下一个元素，如果都不匹配，返回零值

假设B=5，桶的数量2^5=32.

> 10010111 | 000011110110110010001111001010100010010110010101010 │ 01010

用最后的5位01010作为桶的编号，然后用哈希值的高8位找到key在bucket的位置。
最开始桶内没有key，新加入的key会找到第一个空位，放入。
当两个不同的key落入同一个bucket中，发生了哈希冲突，在bucket从前向后找到第一个空位。
这样在查到某个key时，先找到对应的桶，再去遍历bucket里的值

## 扩容
扩容条件: 当map中内存数据/bucket数量>6.5,变会触发扩容
```go
// Maximum average load of a bucket that triggers growth is 6.5.
// Represent as loadFactorNum/loadFactDen, to allow integer math.
loadFactorNum = 13
loadFactorDen = 2

// 扩容条件
func overLoadFactor(count int, B uint8) bool {
	return count > bucketCnt && uintptr(count) > loadFactorNum*(bucketShift(B)/loadFactorDen)
}

// 扩容操作
func hashGrow(t *maptype, h *hmap) {
	bigger := uint8(1)
	if !overLoadFactor(h.count+1, h.B) {
		bigger = 0
		h.flags |= sameSizeGrow
	}
	oldbuckets := h.buckets
	newbuckets, nextOverflow := makeBucketArray(t, h.B+bigger, nil)

	flags := h.flags &^ (iterator | oldIterator)
	if h.flags&iterator != 0 {
		flags |= oldIterator
	}
	// commit the grow (atomic wrt gc)
	h.B += bigger
	h.flags = flags
	h.oldbuckets = oldbuckets
	h.buckets = newbuckets
	h.nevacuate = 0
	h.noverflow = 0

	if h.extra != nil && h.extra.overflow != nil {
		// Promote current overflow buckets to the old generation.
		if h.extra.oldoverflow != nil {
			throw("oldoverflow is not nil")
		}
		h.extra.oldoverflow = h.extra.overflow
		h.extra.overflow = nil
	}
	if nextOverflow != nil {
		if h.extra == nil {
			h.extra = new(mapextra)
		}
		h.extra.nextOverflow = nextOverflow
	}
}
```
过程：扩容会分配一个当前2倍大的空间，并将之前的buckets置位到现在的oldBuckets。
但分配完的数据并不会马上复制到buckets，而通过惰性加载的方式，当访问到的时候才会进行。
注意：扩容的时候B*2，所计算key的哈希值时看低B+1位，所以桶的序号会发生变化，称为 `搬迁rehash`

## 搬迁
```go
// 搬迁操作
func growWork(t *maptype, h *hmap, bucket uintptr) {
	// 确认搬迁老的bucket对应正在使用的bucket
	evacuate(t, h, bucket&h.oldbucketmask())

	// 再搬迁一个bucket
	if h.growing() {
		evacuate(t, h, h.nevacuate)
	}
}

// oldbuckets不为空，没有搬迁完
func (h *hmap) growing() bool {
	return h.oldbuckets != nil
}

func evacuate(t *maptype, h *hmap, oldbucket uintptr) {
    // oldbucket的地址
	b := (*bmap)(add(h.oldbuckets, oldbucket*uintptr(t.bucketsize)))
	newbit := h.noldbuckets()
	if !evacuated(b) {
		// xy表示2倍扩容时对应的前半部分和后半部分
		var xy [2]evacDst
		x := &xy[0]
		// 默认等size扩容，前后的bucket序号不变
		x.b = (*bmap)(add(h.buckets, oldbucket*uintptr(t.bucketsize)))
		x.k = add(unsafe.Pointer(x.b), dataOffset)
		x.e = add(x.k, bucketCnt*uintptr(t.keysize))

		if !h.sameSizeGrow() {
			// 如果不是等size扩容，前后的bucket序号变化，使用y来搬迁
			y := &xy[1]
			y.b = (*bmap)(add(h.buckets, (oldbucket+newbit)*uintptr(t.bucketsize)))
			y.k = add(unsafe.Pointer(y.b), dataOffset)
			y.e = add(y.k, bucketCnt*uintptr(t.keysize))
		}
        // 遍历所有的bucket，包括overflow buckets，b是oldbucket地址
		for ; b != nil; b = b.overflow(t) {
			k := add(unsafe.Pointer(b), dataOffset)
			e := add(k, bucketCnt*uintptr(t.keysize))
			for i := 0; i < bucketCnt; i, k, e = i+1, add(k, uintptr(t.keysize)), add(e, uintptr(t.elemsize)) {
                // 当前cell的top hash值
				top := b.tophash[i]
                // 如果cell为空，即没有key
				if isEmpty(top) {
					b.tophash[i] = evacuatedEmpty
					continue
				}
				if top < minTopHash {
					throw("bad map state")
				}
				k2 := k
				if t.indirectkey() {
					k2 = *((*unsafe.Pointer)(k2))
				}
				var useY uint8
				if !h.sameSizeGrow() {
					// Compute hash to make our evacuation decision (whether we need
					// to send this key/elem to bucket x or bucket y).
					hash := t.hasher(k2, uintptr(h.hash0))
                    // 如果有协程正在遍历map且出现相同的key，算出来的hash值可能不同
					if h.flags&iterator != 0 && !t.reflexivekey() && !t.key.equal(k2, k2) {
						useY = top & 1
						top = tophash(hash)
					} else {
						if hash&newbit != 0 {
							useY = 1
						}
					}
				}

				if evacuatedX+1 != evacuatedY || evacuatedX^1 != evacuatedY {
					throw("bad evacuatedN")
				}

				b.tophash[i] = evacuatedX + useY // evacuatedX + 1 == evacuatedY
				dst := &xy[useY]                 // evacuation destination

				if dst.i == bucketCnt {
					dst.b = h.newoverflow(t, dst.b)
					dst.i = 0
					dst.k = add(unsafe.Pointer(dst.b), dataOffset)
					dst.e = add(dst.k, bucketCnt*uintptr(t.keysize))
				}
				dst.b.tophash[dst.i&(bucketCnt-1)] = top // mask dst.i as an optimization, to avoid a bounds check
                // 执行复制操作
				if t.indirectkey() {
					*(*unsafe.Pointer)(dst.k) = k2 // copy pointer
				} else {
					typedmemmove(t.key, dst.k, k) // copy elem
				}
				if t.indirectelem() {
					*(*unsafe.Pointer)(dst.e) = *(*unsafe.Pointer)(e)
				} else {
					typedmemmove(t.elem, dst.e, e)
				}
                // 定位到下一个cell
				dst.i++
				dst.k = add(dst.k, uintptr(t.keysize))
				dst.e = add(dst.e, uintptr(t.elemsize))
			}
		}
		// 如果没有协程使用oldbuckets，就清除老的oldbuckets，帮助gc
		if h.flags&oldIterator == 0 && t.bucket.ptrdata != 0 {
			b := add(h.oldbuckets, oldbucket*uintptr(t.bucketsize))
			// Preserve b.tophash because the evacuation
			// state is maintained there.
			ptr := add(b, dataOffset)
			n := uintptr(t.bucketsize) - dataOffset
			memclrHasPointers(ptr, n)
		}
	}

	if oldbucket == h.nevacuate {
		advanceEvacuationMark(h, t, newbit)
	}
}
```
为什么遍历map是无序的？

map发生扩容后，会发生key的搬迁，原来落到同一个bucket中的key中，搬迁后有些key值的序号发生变化。
而遍历的过程，是按顺序遍历bucket，同时顺序遍历bucket中的key。搬迁后，有的key位置发生了变化，遍历map就不可能按照原来的顺序了。

同时，每次遍历时，并不是固定的从0号bucket开始，而是随机序号的bucket开始遍历，并且是随机一个序号的cell开始。

1个bucket有两个key的哈希低3位为010,110.原来的B=2，所以他们落在2号桶，现在B=3,010落在2号桶，110落在6号桶。

## 插入数据
```go
func mapassign(t *maptype, h *hmap, key unsafe.Pointer) unsafe.Pointer {
	if h == nil {
		panic(plainError("assignment to entry in nil map"))
	}
	if raceenabled {
		callerpc := getcallerpc()
		pc := funcPC(mapassign)
		racewritepc(unsafe.Pointer(h), callerpc, pc)
		raceReadObjectPC(t.key, key, callerpc, pc)
	}
	if msanenabled {
		msanread(key, t.key.size)
	}
	if h.flags&hashWriting != 0 { // 检测是否竞态读写
		throw("concurrent map writes")
	}
    // 计算key的哈希值
	hash := t.hasher(key, uintptr(h.hash0))

	// 置标记位，表示正在写操作
	h.flags ^= hashWriting

	if h.buckets == nil {
		h.buckets = newobject(t.bucket) // newarray(t.bucket, 1)
	}

again: // 触发rehash，重试
	bucket := hash & bucketMask(h.B)
	if h.growing() {
		growWork(t, h, bucket)
	}
	b := (*bmap)(unsafe.Pointer(uintptr(h.buckets) + bucket*uintptr(t.bucketsize)))
	top := tophash(hash)

	var inserti *uint8
	var insertk unsafe.Pointer
	var elem unsafe.Pointer
bucketloop:
	for {
		for i := uintptr(0); i < bucketCnt; i++ { // 遍历单个bucket
			if b.tophash[i] != top {
				if isEmpty(b.tophash[i]) && inserti == nil {
                    // 找到空位，插入数据
					inserti = &b.tophash[i]
					insertk = add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
					elem = add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
				}
				if b.tophash[i] == emptyRest {
					break bucketloop
				}
				continue
			}
            // 
			k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
			if t.indirectkey() {
				k = *((*unsafe.Pointer)(k))
			}
			if !t.key.equal(key, k) {
				continue
			}
			// 找到相同的key，覆盖value
			if t.needkeyupdate() {
				typedmemmove(t.key, k, key)
			}
			elem = add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
			goto done
		}
		ovf := b.overflow(t)
		if ovf == nil {
			break
		}
		b = ovf
	}
	// 如果增加元素触发扩容，重复
	if !h.growing() && (overLoadFactor(h.count+1, h.B) || tooManyOverflowBuckets(h.noverflow, h.B)) {
		hashGrow(t, h)
		goto again // Growing the table invalidates everything, so try again
	}

	if inserti == nil {
		// 如果所有的buckets满了，重新分配
		newb := h.newoverflow(t, b)
		inserti = &newb.tophash[0]
		insertk = add(unsafe.Pointer(newb), dataOffset)
		elem = add(insertk, bucketCnt*uintptr(t.keysize))
	}

	// store new key/elem at insert position
	if t.indirectkey() {
		kmem := newobject(t.key)
		*(*unsafe.Pointer)(insertk) = kmem
		insertk = kmem
	}
	if t.indirectelem() {
		vmem := newobject(t.elem)
		*(*unsafe.Pointer)(elem) = vmem
	}
	typedmemmove(t.key, insertk, key)
	*inserti = top
	h.count++

done:
	if h.flags&hashWriting == 0 {
		throw("concurrent map writes")
	}
	h.flags &^= hashWriting
	if t.indirectelem() {
		elem = *((*unsafe.Pointer)(elem))
	}
	return elem
}
```
过程：
- 并发读写检查
- 设置写标识
- 计算key的哈希值
- 如果哈希桶是空的，则创建哈希桶，大小为1
- 计算桶链首地址和tophash
- 找到桶链下的所有桶的元素，看key是否存在，如果存在，直接把value写入对应位置
- 在查找过程中，会记录下桶里面第一个空元素的位置
- 如果没有空位置，申请一个溢出桶，并把溢出桶挂载该桶链下
- 把k/v插入空余位置
- map元素总数+1
- 清除写标识

## 删除元素
```go
func mapdelete(t *maptype, h *hmap, key unsafe.Pointer) {
	if h == nil || h.count == 0 {
		if t.hashMightPanic() {
			t.hasher(key, 0) // see issue 23734
		}
		return
	}
	if h.flags&hashWriting != 0 { // 检测是否竞态读写
		throw("concurrent map writes")
	}
    
    // key的哈希值
	hash := t.hasher(key, uintptr(h.hash0))

	// 置位写操作
	h.flags ^= hashWriting

	bucket := hash & bucketMask(h.B)
	if h.growing() {
		growWork(t, h, bucket)
	}
    // 类似于start+index*bucketLen，获取头结点指针
	b := (*bmap)(add(h.buckets, bucket*uintptr(t.bucketsize)))
	bOrig := b
	top := tophash(hash)
search:
    // 外层循环buckets和溢出buckets
	for ; b != nil; b = b.overflow(t) {
        // 内层循环bucket
		for i := uintptr(0); i < bucketCnt; i++ {
			if b.tophash[i] != top {
                // 如果当前tophash是emptyRest表明所有当前bucket里的tophash都是空切溢出bucket也是空
				if b.tophash[i] == emptyRest {
					break search
				}
				continue
			}
			k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
			k2 := k
			if t.indirectkey() {
				k2 = *((*unsafe.Pointer)(k2))
			}
			if !t.key.equal(key, k2) {
				continue
			}
			// 如果key是指针类型，只把指针置为nil
			if t.indirectkey() {
				*(*unsafe.Pointer)(k) = nil
			} else if t.key.ptrdata != 0 {
                // 非指针key，清除数据
				memclrHasPointers(k, t.key.size)
			}
			e := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
			if t.indirectelem() {
				*(*unsafe.Pointer)(e) = nil
			} else if t.elem.ptrdata != 0 {
				memclrHasPointers(e, t.elem.size)
			} else {
				memclrNoHeapPointers(e, t.elem.size)
			}
			b.tophash[i] = emptyOne
			// 如果当前bucket以多个emptyOne状态结尾，把emptyOne改成emptyRest
			// 如果在当前bucket的tophash最后一个位置
			if i == bucketCnt-1 {
                // 当前bucket有溢出且溢出的bucket的tophash下标不是emptyRest
				if b.overflow(t) != nil && b.overflow(t).tophash[0] != emptyRest {
					goto notLast
				}
			} else {
				if b.tophash[i+1] != emptyRest {
					goto notLast
				}
			}
            // 把连续的emptyOne置为emptyRest
			for {
				b.tophash[i] = emptyRest
				if i == 0 {
					if b == bOrig {
						break // beginning of initial bucket, we're done.
					}
					// Find previous bucket, continue at its last entry.
					c := b
					for b = bOrig; b.overflow(t) != c; b = b.overflow(t) {
					}
					i = bucketCnt - 1
				} else {
					i--
				}
				if b.tophash[i] != emptyOne {
					break
				}
			}
		notLast:
			h.count--
			break search
		}
	}

	if h.flags&hashWriting == 0 {
		throw("concurrent map writes")
	}
	h.flags &^= hashWriting
}
```
过程：
- 并发读写检查
- 设置写标识
- 计算key的哈希值
- 计算桶链首地址和tophash
- 找到桶链下所有桶元素，如果找到key，处理
- map总元素-1
- 清除写标识

## 查找元素
查找有多个实现，对应
`v:=m[k]`;
`v,ok:=m[k]`;
`k,v:=range m`;
`k:=range m`
```go
func mapaccess1(t *maptype, h *hmap, key unsafe.Pointer) unsafe.Pointer {
	// 如果map为nil，返回零值
	if h == nil || h.count == 0 {
		if t.hashMightPanic() {
			t.hasher(key, 0) // see issue 23734
		}
		return unsafe.Pointer(&zeroVal[0])
	}
	if h.flags&hashWriting != 0 { //检测竞态读写
		throw("concurrent map read and map write")
	}
    // key的哈希
	hash := t.hasher(key, uintptr(h.hash0))
	m := bucketMask(h.B)
	b := (*bmap)(add(h.buckets, (hash&m)*uintptr(t.bucketsize)))
	if c := h.oldbuckets; c != nil {
		if !h.sameSizeGrow() {
			// There used to be half as many buckets; mask down one more power of two.
			m >>= 1
		}
		oldb := (*bmap)(add(c, (hash&m)*uintptr(t.bucketsize)))
		if !evacuated(oldb) {
			b = oldb
		}
	}
	top := tophash(hash)
bucketloop:
	for ; b != nil; b = b.overflow(t) {
		for i := uintptr(0); i < bucketCnt; i++ {
			if b.tophash[i] != top {
				if b.tophash[i] == emptyRest {
					break bucketloop
				}
				continue
			}
			k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
			if t.indirectkey() {
				k = *((*unsafe.Pointer)(k))
			}
			if t.key.equal(key, k) {
				e := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
				if t.indirectelem() {
					e = *((*unsafe.Pointer)(e))
				}
				return e
			}
		}
	}
	return unsafe.Pointer(&zeroVal[0])
}
```
如果oldbucket存在，会在oldbucket里寻找，如果已经搬迁了，就到新的bucket里查找。

通过阅读map的源码可以看到，如果同时对一个map进行读写操作，会panic，所以需要在用户层进行锁控制。
key经过哈希后，低位用来定位buckets，高位用来对bucket寻址，大大缩小了key的查找范围。
在搬迁过程中，oldbucket到newbucket是值拷贝的话开销会很大，如果是指针的话开销会减小。