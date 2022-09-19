---
title: "map三步曲之二拉链法"
date: 2022-03-07T11:16:04+08:00
draft: false

tags: ['map','analysis']
categories: ["go"]
comment: true
toc: true
autoCollapseToc: false
---

## 一、拉链法

![拉链法](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/12/09/map_link.png)

之前提到过的拉链法，看[这里](https://www.toutiao.com/i7038589955723035143/)

## 二、map底层数据结构

map中的数据被存放在一个数组中，数组的元素是桶(bucket)，每个桶至多包含8个键值对数据。

我们先来看看存储数据的结构。

---

hmap.buckets的元素是一个`bmap`结构。直接在`map.go`文件中是看不到的，它是从编译步骤开始将字节分割成这些字段。

| 字段     | 解释                                                         |
| -------- | ------------------------------------------------------------ |
| topbits  | 长度为8的数组，元素为：key获取的hash的高8位，遍历时对比使用，提高性能。 |
| keys     | 长度为8的数组，[]keytype，元素为：具体的key值                |
| elems    | 长度为8的数组，[]elemtype，元素为：键值对的key对应的值       |
| overflow | 指向hmap.extra.overflow溢出桶里的`bmap`，上面字段长度为8，最多存8组键值对，存满了就往这项的这个bmap存 |

在src/cmd/compile/internal/gc/reflect.go文件中，可以看到把这些字段加入到`bmap`结构体中。
```go
// bmap makes the map bucket type given the type of the map.
func bmap(t *types.Type) *types.Type {
	...
	field := make([]*types.Field, 0, 5)

	// The first field is: uint8 topbits[BUCKETSIZE].
	arr := types.NewArray(types.Types[TUINT8], BUCKETSIZE)
	field = append(field, makefield("topbits", arr))

	arr = types.NewArray(keytype, BUCKETSIZE)
	arr.SetNoalg(true)
	keys := makefield("keys", arr)
	field = append(field, keys)

	arr = types.NewArray(elemtype, BUCKETSIZE)
	arr.SetNoalg(true)
	elems := makefield("elems", arr)
	field = append(field, elems)

	otyp := types.NewPtr(bucket)
	if !types.Haspointers(elemtype) && !types.Haspointers(keytype) {
		otyp = types.Types[TUINTPTR]
	}
	overflow := makefield("overflow", otyp)
	field = append(field, overflow)

	t.MapType().Bucket = bucket

	bucket.StructType().Map = t
	return bucket
}
```

这个是bmap的结构图

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/12/09/map_bucket.png)

key和value是各自存储的，虽然会使代码组织结构稍显复杂，但好处是能消除例如`map[int64]int32`所需要的填充(padding)，使得**内存对齐**更加方便。

此外，在8个键值对数据后面有一个overflow指针，因为桶中最多只能装8个键值对，如果有多余的键值对落到当前桶中，那么就需要再构建一个桶（溢出桶），通过overflow指针连接起来。

![hmap](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/12/09/map_hmap.png)

## 三、创建map

map初始化有两种方式

```go
make(map[k]v)
make(map[k]v,hint)
```

对于不指定初始化大小和初始化大小`hint<=8`时，会调用`makemap_small`函数，并直接从堆上分配。

```go
func makemap_small() *hmap {
	h := new(hmap)
	h.hash0 = fastrand()
	return h
}
```

当`hint>8`时，调用`makemap`函数。

如果编译器认为map或者第一个bucket可以直接在栈上创建，`h`或`bucket`可能非nil。

- 如果`h!=nil`，`map`可以直接用`h`创建

- 如果`h.buckets!=nil`，那么`h`指向的`bucket`可以作为`map`的第一个`bucket`使用

```go
func makemap(t *maptype, hint int, h *hmap) *hmap {
	// math.MulUintptr返回hint与t.bucket.size的乘积，并判断该乘积是否溢出。
	mem, overflow := math.MulUintptr(uintptr(hint), t.bucket.size)
	if overflow || mem > maxAlloc {
		hint = 0
	}

	// initialize Hmap
	if h == nil {
		h = new(hmap)
	}
	// 得到哈希种子
	h.hash0 = fastrand()

	// 根据输入的元素个数hint，找到能装下这些元素的B值
	B := uint8(0)
	for overLoadFactor(hint, B) {
		B++
	}
	h.B = B

	// 分配初始哈希表
	// 如果 B==0，那么buckets字段会在后续的mapassign方法中lazily分配
	if h.B != 0 {
		var nextOverflow *bmap
		// makeBucketArray创建一个map的底层保存buckets的数组，至少会分配 B^2 的大小
		h.buckets, nextOverflow = makeBucketArray(t, h.B, nil)
		if nextOverflow != nil {
			h.extra = new(mapextra)
			h.extra.nextOverflow = nextOverflow
		}
	}

	return h
}
```

分配bucket数组的`makeBucketArray`函数

```go
func makeBucketArray(t *maptype, b uint8, dirtyalloc unsafe.Pointer) (buckets unsafe.Pointer, nextOverflow *bmap) {
	base := bucketShift(b)
	nbuckets := base
	// 对于小的b值（小于4），即桶的数量小于16时，使用溢出桶的可能性很小，对于此情况，避免计算开销
	if b >= 4 {
		// 当桶的数量>=16时，正常情况下会额外创建2^(b-4)个溢出桶
		nbuckets += bucketShift(b - 4)
		sz := t.bucket.size * nbuckets
		up := roundupsize(sz)
		if up != sz {
			nbuckets = up / t.bucket.size
		}
	}

	// 如果为nil，会分配一个新的底层数组
	// 如果不为nil，指向曾经分配过的底层数组，该底层数组是由之前同样的t和b参数通过makeBucketArray分配的，如果数组不为空，需要把该数组之前的数据清空并复用。
	if dirtyalloc == nil {
		buckets = newarray(t.bucket, int(nbuckets))
	} else {
		buckets = dirtyalloc
		size := t.bucket.size * nbuckets
		if t.bucket.ptrdata != 0 {
			memclrHasPointers(buckets, size)
		} else {
			memclrNoHeapPointers(buckets, size)
		}
	}

	// 即b>=4的情况下，会预分配一些溢出桶
	// 为了把跟踪这些溢出桶的开销降到最低，使用了以下约定：
	// 如果预分配的溢出桶的overflow指针为nil，那么可以通过指针碰撞（bumping the pointer）获得更多可用桶。
	// （关于指针碰撞：假设内存是绝对规整的，所有用过的内存都放在一边，空闲的内存放在另一边，中间放着一个指针作为分界点的指示器，
	// 那所分配内存就仅仅是把那个指针向空闲空间那边挪动一段与对象大小相等的距离，这种分配方式称为“指针碰撞”）
	// 对于最后一个溢出桶，需要一个安全的非nil指针指向它
	if base != nbuckets {
		nextOverflow = (*bmap)(add(buckets, base*uintptr(t.bucketsize)))
		last := (*bmap)(add(buckets, (nbuckets-1)*uintptr(t.bucketsize)))
		// 把溢出桶的最后一个bmap的overflow指向正常桶的第一个bmap
		last.setoverflow(t, (*bmap)(buckets))
	}
	return buckets, nextOverflow
}
```

根据上述代码，我们能确定在正常情况下，正常桶和溢出桶在内存中的存储空间是连续的，只是被`hmap` 中的不同字段引用而已。

### 3.1、哈希函数

```go
func fastrand() uint32 {
	mp := getg().m
	s1, s0 := mp.fastrand[0], mp.fastrand[1]
	s1 ^= s1 << 17
	s1 = s1 ^ s0 ^ s1>>7 ^ s0>>16
	mp.fastrand[0], mp.fastrand[1] = s0, s1
	return s0 + s1
}
```

`fastrand`的初始化是在go编译过程中，通过调用`schedinit`函数初始化

```go
func schedinit() {
	...
	fastrandinit() // must run before mcommoninit
	mcommoninit(_g_.m, -1)
	alginit()       // maps must not be used before this call
    ...
}
```

## 四、map操作

首先，我们先理解一个key如何在map中存储。

例如，先要置一key于map中，该key经过哈希后，得到的哈希值如下：

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/12/09/map_tophash.png)

哈希值低位（low-order bits）用于选择桶，哈希值高位（high-order bits）用于在一个独立的桶中区别出键。

当B等于5时，buckets数组的长度，即桶的数量是32（2^5^），那么我们选择的哈希值低5位，即`01010`,它的二进制是10，代表10号桶。

再用哈希值的**高8位**，找到此key在桶中的位置。

最开始桶中没有key，那么新加入的key和value就会被放入第一个key空位和value空位上。

```go
// tophash calculates the tophash value for hash.
func tophash(hash uintptr) uint8 {
	top := uint8(hash >> (sys.PtrSize*8 - 8)) // sys.PtrSize=8
	if top < minTopHash {
		top += minTopHash
	}
	return top
}
```

当两个不同的key落在了同一个桶中时，这时就发生了哈希冲突。

> **go采用链地址法**
>
> 在桶中按照顺序寻到的第一个空位记录下来，后续在该桶和它的溢出桶中如果没有发现存在该key，将该key置于第一个空位；
>
> 否则，就去该桶的溢出桶中寻找空位，
>
> 如果没有空位，不存在溢出桶，则添加溢出桶，并将其置于溢出桶的第一个空位

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/12/09/map_hash.png)

上面的B值为5，所以桶的数量为32。通过哈希函数计算出待插入key的哈希值，低5位哈希值为00110，对应6号桶；高8位10010111，十进制151，
由于桶中前6个已经有正常哈希值填充了（遍历），所以将151对应的高位哈希值放置在7号位上， 对应将key和value分别置于相应的第7位。