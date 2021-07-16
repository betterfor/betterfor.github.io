# 深入理解Golang Map


# 前言

Map是一种常用的数据结构，通常用于存储无序的键值对。但是，Map在Golang中是如何实现的？

- 如果判断Map中是否包含某个key？
- Map是如何实现增删改查的？
- Map的扩容机制是什么？
- Map是线程安全的吗？

# 概述

我们在使用过程中，发现map有如下特点：

- map是一个无序的key/value集合
- map中所有的key是不相同的
- 通过给定的key，可以在常数时间复杂度(`O(1)`)内查找、更新或删除相应的value

而想要实现一个性能优异的map，需要解决以下关键点：

- 哈希算法
- 处理哈希冲突
- 扩容策略

# 哈希算法

## 什么是哈希算法？

哈希算法又称哈希函数/散列算法/散列函数，是一种从任何一种数据中创建小的数字“指纹”的方法。哈希算法把消息或数据压缩成摘要，使得数据量变小，将数据的格式固定下来。

哈希算法最重要的特点就是：

- 相同的输入一定得到相同的输出；
- 不同的输入大概率得到不同的输出。

## Map中为什么需要哈希算法？

Map中使用哈希算法是为了实现快速查找和定位。

一个优秀的哈希函数应该包含以下特性：
- 均匀性：一个好的哈希函数应该在其输出范围内尽可能均匀地映射，也就是说，应以大致相同的概率生成输出范围内的每个哈希值。
- 高效率：哈希效率要高，即使很长的输入参数也能快速计算出哈希值。
- 可确定性：哈希过程必须是确定性的，这意味着对于给定的输入值，它必须始终生成相同的哈希值。
- 雪崩效应：微小的输入值变化也会让输出值发生巨大的变化。
- 不可逆：从哈希函数的输出值不可反向推导出原始的数据。

## 常见的哈希算法

![常见的哈希算法](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/14/3936338261.png)

下图是不同哈希算法的性能对比，测试环境是 Open-Source SMHasher program by Austin Appleby ，在 Windows 7 上通过 Visual C 编译，只有一个线程，CPU 内核是 Core 2 Duo @3.0GHz。

其中，第一栏是哈希算法名称，第二栏是速度的对比，第三栏是哈希质量。从表中数据看，质量最高、速度最快的是 xxHash。

![hash benchmarks](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/14/455142580.png)

## Golang使用的哈希算法

Golang 选择哈希算法时，根据 CPU 是否支持 AES 指令集进行判断 ，如果 CPU 支持 AES 指令集，则使用 Aes Hash，否则使用 memhash。

### AES Hash

AES 指令集全称是高级加密标准指令集（或称英特尔高级加密标准新指令，简称AES-NI），是一个 x86指令集架构的扩展，用于 Intel 和 AMD 处理器。
利用 AES 指令集实现哈希算法性能很优秀，因为它能提供硬件加速。

查看 CPU 是否支持 AES 指令集：

```shell
$ cat /proc/cpuinfo | grep aes
flags           : fpu vme de pse tsc msr pae mce cx8 apic sep mtrr pge mca cmov pat pse36 clflush dts mmx fxsr sse sse2 ss ht syscall nx pdpe1gb rdtscp lm constant_tsc arch_perfmon pebs bts nopl xtopology tsc_reliable nonstop_tsc aperfmperf eagerfpu pni pclmulqdq ssse3 fma cx16 pcid sse4_1 sse4_2 x2apic movbe popcnt tsc_deadline_timer aes xsave avx f16c rdrand hypervisor lahf_lm abm 3dnowprefetch epb fsgsbase tsc_adjust bmi1 hle avx2 smep bmi2 invpcid rtm rdseed adx smap xsaveopt dtherm ida arat pln pts
```

相关代码：
runtime/alg.go
asm_amd64.s
asm_arm64.s

### memhash

网上没有找到这个哈希算法的作者信息，只在 Golang 的源码中有这几行注释，说它的灵感来源于 xxhash 和 cityhash。

```shell
// Hashing algorithm inspired by
//   xxhash: https://code.google.com/p/xxhash/
// cityhash: https://code.google.com/p/cityhash/
```

相关代码：
runtime/hash64.go
runtime/hash32.go

# 处理哈希冲突

通常情况下，哈希算法的输入范围一定会远远大于输出范围，所以当输入的key足够多时一定会遇到冲突，这时需要一些方法来解决哈希冲突问题。

**比较常用的哈希冲突解决方案有链地址法和开放寻址法。**

Golang 及多数编程语言都使用链地址法处理哈希冲突。

## 链地址法

>  链地址法一般会使用数组加上链表实现，有些语言会引入红黑树以优化性能。

下面以一个简单的哈希函数`H(key)=key MOD 7`（除数取余法）对一组元素[50,700,76,85,92,73,101]进行映射。

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/14/链地址法.png)



在遍历当前桶中的链表时，会遇到以下两种情况：

1、找到键相同的键值对，则更新键对应的值

2、没有找到键相同的键值对，则在链表的末尾追加新键值对。

特点：平均查找长度短，用于存储节点的内存是动态申请的，可以节省较多内存。

## 开放地址法

开放地址法的核心思路是：对数组中的元素依次探测和比较，以判断目标键值对是否存在于map中。

对于链地址法而言，槽位数m与键的数目n是没有直接关系的。但是对于开放寻址法而言，所有的元素都是存储在hash表中，所以无论如何都要保证哈希表的槽位数m>=键的数目n。（必要时，需要对哈希表进行动态扩容）

开放寻址法有多种方式：线性探测法、平方探测法、随机探测法、双重哈希法。

- 线性探测法

设`Hash(key)`表示关键字`key`的哈希值，表示哈希表的槽位数（哈希表的大小）。

线性探测法可以表示为：

- 如果`Hash(x)%M`已经有数据，则尝试`(Hash(x)+1)%M`
- 如果`(Hash(x)+1)%M`有数据，则尝试`(Hash(x)+2)%M`
- 如果`(Hash(x)+2)%M`有数据，则尝试`(Hash(x)+3)%M`
- ...

同样以哈希函数`H(key)=key MOD 7`（除数取余法）对一组元素[50,700,76,85,92,73,101]进行映射。

![开放地址法](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/14/开放地址法.png)

如上图所示，当我们向当前map写入新数据时发生了冲突，就将键值写入到下一个不为空的位置。

开放地址中对性能影响最大的是**装载因子**，它是数组中元素数量和数组大小的比值。随着装载因子的增加，线性探测的平均用时会逐渐增加，这会影响map的读写性能。

## 两种方案的比较

对于开放寻址法而言，它只有数组一种数据结构就可完成存储，继承了数组的优点，对CPU缓存友好，易于序列化操作。但是它对内存的利用率不如链地址法，且发生冲突时代价更高。当数据量明确、装载因子小，适合采用开放寻址法。

链表节点可以在需要时再创建，不必像开放寻址法那样事先申请好足够内存，因此链地址法对于内存的利用率会比开方寻址法高。
链地址法对装载因子的容忍度会更高，并且适合存储大对象、大数据量的哈希表。而且相较于开放寻址法，它更加灵活，支持更多的优化策略，比如可采用红黑树代替链表。但是链地址法需要额外的空间来存储指针。

在Python中dict在发生哈希冲突时采用的开放寻址法，而java的HashMap采用的是链地址法。

Go解决哈希冲突的方式是链地址法，即通过使用数组+链表的数据结构来表达map。

# 扩容策略

随着 Map 中元素的增加，发生哈希冲突的概率会增加，Map 的读写性能也会下降，所以我们需要更多的桶和更大的内存来保证 Map 的读写性能。

在实际应用中，当装载因子超过某个阈值时，会动态地增加 Map 长度，实现自动扩容。

每当 Map 长度发生变化后，所有 key 在 Map 中对应的索引需要重新计算。如果一个一个计算原 Map 中的 key 的索引并插入到新 Map 中，这种一次性扩容方式是达不到生产环境的要求的，因为时间复杂度太高了O(n)，在数据量大的情况下性能会很差。

在实际应用中，Map 扩容都是分多次、渐进式地完成，而不是一性次完成扩容。

# 具体实现

Golang Map的具体定义在`src/runtime/map.go`文件中。

## 常量定义

```go
const (
	// 一个桶中最多能装载的键值对的个数为8
	bucketCntBits = 3
	bucketCnt     = 1 << bucketCntBits

	// 触发扩容的装载因此13/2=6.5
	loadFactorNum = 13
	loadFactorDen = 2

	// 键和值超过128个字节，就会被转为指针
	maxKeySize  = 128
	maxElemSize = 128

	// 数据偏移量是bmap结构体的大小，需要对齐。
	// 对于amd64p32而言，意味着，即使指针时32位的，也是64位对齐
	dataOffset = unsafe.Offsetof(struct {
		b bmap
		v int64
	}{}.v)

	// 每个桶（如果有溢出，则包含它的overflow的链桶）在搬迁完成状态(evacuated* states)下，要么包含它的所有键值对，
	// 要么一个都不包含（但不包括调用evacuate()方法阶段，该方法调用只会在对map发起write时发生，在该阶段其他goroutine是无法查看该map的）。
	// 简单的说，桶里的数据要么一起搬走，要么一个都还未搬。
	// tophash除了放置正常的高8位hash值，还会存储一些特殊状态值（标志该cell的搬迁状态）。正常的tophash值，最小应该是5，以下列出的就是一些特殊状态值。

	// 表示cell为空，并且比它高索引位的cell或者overflows中的cell都是空的。（初始化bucket时，就是该状态）
	emptyRest = 0 // this cell is empty, and there are no more non-empty cells at higher indexes or overflows.
	// 空的cell，cell已经被搬迁到新的bucket
	emptyOne = 1 // this cell is empty
	// 键值对已经搬迁完毕，key在新buckets数组的前半部分
	evacuatedX = 2 // key/elem is valid.  Entry has been evacuated to first half of larger table.
	// 键值对已经搬迁完毕，key在新buckets数组的后半部分
	evacuatedY = 3 // same as above, but evacuated to second half of larger table.
	// cell为空，整个bucket已经搬迁完毕
	evacuatedEmpty = 4 // cell is empty, bucket is evacuated.
	// tophash的最小正常值
	minTopHash = 5 // minimum tophash for a normal filled cell.

	// flags
	// 可能有迭代器在使用buckets
	iterator = 1 // there may be an iterator using buckets
	// 可能有迭代器在使用oldbuckets
	oldIterator = 2 // there may be an iterator using oldbuckets
	// 有协程正在向map写入key
	hashWriting = 4 // a goroutine is writing to the map
	// 等量扩容
	sameSizeGrow = 8 // the current map growth is to a new map of the same size

	// 用于迭代器检查的bucket ID
	noCheck = 1<<(8*sys.PtrSize) - 1
)
```

## 装载因子为什么是6.5？

这个值太大会导致溢出桶（overflow buckets）过多，查找效率降低，过小则会浪费存储空间。

据 Google 开发人员称，这个值是一个测试程序测量出来的一个经验值。

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/14/2938756258.png)

%overflow ：溢出率，平均每个桶（bucket）有多少键值对 key/value 时会溢出。

bytes/entry ：存储一个键值对 key/value 时， 所需的额外存储空间（字节）。

hitprobe ：查找一个存在的 key 时，所需的平均查找次数。

missprobe ：查找一个不存在的 key 时，所需的平均查找次数。

经过这几组测试数据，最终选定 6.5 作为临界的装载因子。

## map header定义

```go
// A header for a Go map.
type hmap struct {
	// Note: the format of the hmap is also encoded in cmd/compile/internal/gc/reflect.go.
	// Make sure this stays in sync with the compiler's definition.
	// 键值对的数量
	count int // # live cells == size of map.  Must be first (used by len() builtin)
	// 标识状态
	flags uint8
	// 2^B = len(buckets)
	B uint8 // log_2 of # of buckets (can hold up to loadFactor * 2^B items)
	// 溢出桶里bmap大致数量
	noverflow uint16 // approximate number of overflow buckets; see incrnoverflow for details
	// hash因子
	hash0 uint32 // hash seed
	// 指向一个数组（连续内存空间），数组类型为[]bmap，bmap类型就是存在键值对的结构
	buckets unsafe.Pointer // array of 2^B Buckets. may be nil if count==0.
	// 扩容时，存放之前的buckets
	oldbuckets unsafe.Pointer // previous bucket array of half the size, non-nil only when growing
	// 分流次数，成倍扩容分流操作计数的字段
	nevacuate uintptr // progress counter for evacuation (buckets less than this have been evacuated)
	// 溢出桶结构，正常桶里面某个bmap存满了，会使用这里面的内存空间存放键值对
	extra *mapextra // optional fields
}
```

在Golang的map header结构中，包含2个指向桶数组的指针，buckets指向新的桶数组，oldbuckets指向旧的桶数组。

oldbuckets在哈希表扩容时用于保存旧桶数据，它的大小是当前buckets的一半。

hmap的最后一个字段指向一个mapextra结构的指针。

```go
// mapextra holds fields that are not present on all maps.
type mapextra struct {
	// If both key and elem do not contain pointers and are inline, then we mark bucket
	// type as containing no pointers. This avoids scanning such maps.
	// However, bmap.overflow is a pointer. In order to keep overflow buckets
	// alive, we store pointers to all overflow buckets in hmap.extra.overflow and hmap.extra.oldoverflow.
	// overflow and oldoverflow are only used if key and elem do not contain pointers.
	// overflow contains overflow buckets for hmap.buckets.
	// oldoverflow contains overflow buckets for hmap.oldbuckets.
	// The indirection allows to store a pointer to the slice in hiter.
	// 溢出桶，当正常桶存满后就使用hmap.extra.overflow的bmap
	// bmap.overflow是指针类型，存放了对应使用的hmap.extra.overflow里的bmap地址
	overflow *[]*bmap
	// 扩容时存放之前的overflow
	oldoverflow *[]*bmap

	// nextOverflow holds a pointer to a free overflow bucket.
	// 指向溢出桶里下一个可以使用的bmap
	nextOverflow *bmap
}
```

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/14/3369318540.png)

如上图所示map里的桶就是`bmap`，每一个bmap能存储8个键值对。

当map中存储的数据过多，单个桶装满时就会使用extra.overflow中的桶存储溢出的数据。

上面的黄色的bmap就是正常桶，绿色的bmap就是溢出桶。

## 桶的结构体bmap

```go
// A bucket for a Go map.
type bmap struct {
	// tophash generally contains the top byte of the hash value
	// for each key in this bucket. If tophash[0] < minTopHash,
	// tophash[0] is a bucket evacuation state instead.
	// tophash包含此桶中每个键的哈希值最高字节（高8位）信息（也就是前面所述的high-order bits）。
	// 如果tophash[0] < minTopHash，tophash[0]则代表桶的搬迁（evacuation）状态。
	tophash [bucketCnt]uint8
	// Followed by bucketCnt keys and then bucketCnt elems.
	// NOTE: packing all the keys together and then all the elems together makes the
	// code a bit more complicated than alternating key/elem/key/elem/... but it allows
	// us to eliminate padding which would be needed for, e.g., map[int64]int8.
	// Followed by an overflow pointer.
}
```

bmap结构体其实不止包含tophash字段，由于 Map 中可能存储不同类型的键值对，并且 Golang 不支持泛型，所以键值对占据的内存空间大小只能在编译时进行推导，这些额外字段在运行时都是通过计算内存地址的方式直接访问的，所以 bmap 的定义中就没有包含这些额外的字段。

这会在编译期间的[cmd/compile/internal/gc/reflect.go](https://github.com/golang/go/blob/c6d89dbf9954b101589e2db8e170b84167782109/src/cmd/compile/internal/gc/reflect.go#L82)重建bmap的结构。

```go
type bmap struct {
    topbits  [8]uint8		// 长度为8的数组，元素为：key获取的hash的高8位，遍历时对比使用，提高性能。
    keys     [8]keytype		// 长度为8的数组，[]keytype，元素为：具体的key值
    values   [8]valuetype	// 长度为8的数组，[]elemtype，元素为：键值对的key对应的值
    overflow uintptr		// 指向hmap.extra.overflow溢出桶里的`bmap`，上面字段长度为8，最多存8组键值对，存满了就往这项的这个bmap存
}
```

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

   // If keys and elems have no pointers, the map implementation
   // can keep a list of overflow pointers on the side so that
   // buckets can be marked as having no pointers.
   // Arrange for the bucket to have no pointers by changing
   // the type of the overflow field to uintptr in this case.
   // See comment on hmap.overflow in runtime/map.go.
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

编译期间还会生成`maptype`结构体，定义在[runtime/type.go](https://github.com/golang/go/blob/c6d89dbf9954b101589e2db8e170b84167782109/src/runtime/type.go#L365)文件中：

```go
type maptype struct {
	typ    _type
	key    *_type
	elem   *_type
	bucket *_type // internal type representing a hash bucket
	// function for hashing keys (ptr to key, seed) -> hash
	// hasher的第一个参数就是指向key的指针，h.hash0=fastrand()得到的hash0，就是hasher方法的第二个参数
	// hasher方法返回的就是hash值
	hasher     func(unsafe.Pointer, uintptr) uintptr
	keysize    uint8  // size of key slot
	elemsize   uint8  // size of elem slot
	bucketsize uint16 // size of bucket
	flags      uint32
}
```

下面是map的整体结构图

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/14/2018590655.png)

bmap是存放key/value的地方，下面是bmap的内部组成：

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/14/3471157346.png)

上图是桶的内存模型，HOB Hash 指的是 tophash。注意到 key 和 value 是各自放在一起的，并不是 key/value/key/value/... 这样的形式。

如果按照 key/value/key/value/... 这样的形式存储，为了内存对齐，在每一对 key/value 后面都要额外 padding 7 个字节；

而将所有的 key，value 分别绑定到一起，这种形式 key/key/.../value/value/...，则只需要在最后添加 padding。

## 新建map

新建map有两种方式

```go
make(map[k]v)
make(map[k]v,hint)
```

对于不指定初始化大小或初始化大小`hint<=8`时，会调用`makemap_small`函数，直接从堆上分配。当`hint>8`时，调用`makemap`函数。

而我们考虑的是`makemap`函数：

主要工作就是分配内存并初始化hmap结构体的各项字段，例如计算B的大小，设置哈希种子hash0等。

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

	// Find the size parameter B which will hold the requested # of elements.
	// For hint < 0 overLoadFactor returns false since hint < bucketCnt.
	// 根据输入的元素个数hint，找到能装下这些元素的B值
	B := uint8(0)
	for overLoadFactor(hint, B) {
		B++
	}
	h.B = B

	// 分配初始哈希表
	// 如果 B==0，那么buckets字段会在后续的mapassign方法中lazily分配
	// allocate initial hash table
	// if B == 0, the buckets field is allocated lazily later (in mapassign)
	// If hint is large zeroing this memory could take a while.
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

在 B 不为 0 的情况下，会调用 makeBucketArray 函数初始化桶。

- 当 B < 4 的时候，初始化 hmap 只会生成 8 个桶，不生成溢出桶，因为数据少几乎不可能用到溢出桶；
- 当 B >= 4 的时候，会额外创建 2^(B−4) 个溢出桶。

## 查找key

- key经过哈希后得到64位哈希值

- 用哈希值最后B个bit位计算它落在哪个桶

- 用哈希值高8位计算它在桶中的索引位置。

### 哈希函数

在初始化go程序环境(`src/runtime/proc.go`中的`schedinit`)，需要通过`alginit`方法完成对哈希的初始化。

> `maps must not be used before this call`

```go
func alginit() {
	// Install AES hash algorithms if the instructions needed are present.
	if (GOARCH == "386" || GOARCH == "amd64") &&
		cpu.X86.HasAES && // AESENC
		cpu.X86.HasSSSE3 && // PSHUFB
		cpu.X86.HasSSE41 { // PINSR{D,Q}
		initAlgAES()
		return
	}
	if GOARCH == "arm64" && cpu.ARM64.HasAES {
		initAlgAES()
		return
	}
	getRandomData((*[len(hashkey) * sys.PtrSize]byte)(unsafe.Pointer(&hashkey))[:])
	hashkey[0] |= 1 // make sure these numbers are odd
	hashkey[1] |= 1
	hashkey[2] |= 1
	hashkey[3] |= 1
}
```
对于哈希算法的选择，程序会根据当前架构判断是否支持AES hash，代码实现位于`src/runtime/asm_{386,amd64,arm64}.s中；
如果不支持，其hash函数则根据xxhash算法（https://code.google.com/p/xxhash/）和cityhash算法（https://code.google.com/p/cityhash/）启发而来，
代码分别对应于32位（src/runtime/hash32.go）和64位机器（src/runtime/hash32.go）中

### tophash

桶数B，如果B=5，那么桶的总数为2^5=32.

例如，有一个key经过哈希后，得到的哈希值为：

```go
10010111 | 000011110110110010001111001010100010010110010101010 │ 01010
```

取最后5个bit位，也就是`01010`，值为`10`，定位到10号桶。

再用哈希值的高8位，找到此key在当前桶（10号桶）中的索引位置。如果桶中没有key，新加入的key会放入第一个空位

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/14/201938246.png)

```go
// tophash calculates the tophash value for hash.
func tophash(hash uintptr) uint8 {
   top := uint8(hash >> (sys.PtrSize*8 - 8))
   if top < minTopHash {
      top += minTopHash
   }
   return top
}
```

当两个不同的key落在了同一个桶中时，这时就发生了哈希冲突。

go采用链地址法：在桶中按照顺序寻到第一个空位并记录下来，后续在该桶和它的溢出桶中均为发现存在的该key，将key置于第一个空位；否则，去该桶的溢出桶中寻找空位，如果没有溢出桶，添加溢出桶，并将其置于溢出桶的第一个空位.

### 查找操作

- v:=m[k],对应的是mapaccess1方法
- v,ok:=m[k]，对应的是mapaccess2方法

mapaccess2和mapaccess1的方法逻辑相同，只是多返回了bool返回值。

mapaccessK是for range的逻辑，返回了key和value，代码逻辑也是一样。

我们来看看`mapaccess1`函数：

```go
func mapaccess1(t *maptype, h *hmap, key unsafe.Pointer) unsafe.Pointer {
	// 如果map为空或元素个数为0，返回零值
	if h == nil || h.count == 0 {
		if t.hashMightPanic() {
			t.hasher(key, 0) // see issue 23734
		}
		return unsafe.Pointer(&zeroVal[0])
	}
	// 如果flag为hashWriting，则报错，表示map不是并发安全的
	if h.flags&hashWriting != 0 {
		throw("concurrent map read and map write")
	}
	// 不同类型的key，会使用不同的hash算法，在alg.go中的typehash的逻辑
	hash := t.hasher(key, uintptr(h.hash0))
	m := bucketMask(h.B)
	// 按位与操作，找到对应的bucket
	b := (*bmap)(add(h.buckets, (hash&m)*uintptr(t.bucketsize)))
	// 如果oldbuckets不为空，那么证明map发生了扩容
	// 如果有扩容发生，老的buckets中的数据可能还未搬迁到新的bucket中
	// 所以要先在老的bucket中查找
	if c := h.oldbuckets; c != nil {
		if !h.sameSizeGrow() {
			// There used to be half as many buckets; mask down one more power of two.
			m >>= 1
		}
		oldb := (*bmap)(add(c, (hash&m)*uintptr(t.bucketsize)))
		// 如果在oldbuckets中的tophash[0]的值，为evacuatedX，evacuatedY，evacuatedEmpty其中之一
		// 则evacuated()返回为true，代表搬迁完成
		// 因此，只有当搬迁未完成时，未完成时，才会从此oldbuckets中遍历
		if !evacuated(oldb) {
			b = oldb
		}
	}

	// 取出当前key的tophash值
	top := tophash(hash)
	// 以下是查找的核心逻辑
	// 双重循环遍历：外层循环是从桶到溢出桶遍历；内层是桶中的cell遍历
	// 跳出循环的条件有三种：第一种是找到key值；第二种是当前桶无溢出桶；第三种是当前桶中有cell位的tophash=emptyRest，代表桶还未使用，无需遍历
bucketloop:
	for ; b != nil; b = b.overflow(t) {
		for i := uintptr(0); i < bucketCnt; i++ {
			// 判断tophash是否相等
			if b.tophash[i] != top {
				if b.tophash[i] == emptyRest {
					break bucketloop
				}
				continue
			}
			// 因为在bucket中的key使用连续的存储空间存储，因此可以通过bucket+数据偏移量（bmap结构体大小）+keysize的大小得到k的大小
			// 同理，value的地址也是相似的算法，只是要加上8个keysize的内存地址
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

这里提一下定位key和value的方法：

```go
// key的定位公式
k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
// value的定位公式
e := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
```

## 插入key

插入key的过程和查找key的过程大体一致。

```go
// Like mapaccess, but allocates a slot for the key if it is not present in the map.
func mapassign(t *maptype, h *hmap, key unsafe.Pointer) unsafe.Pointer {
	if h == nil {
		panic(plainError("assignment to entry in nil map"))
	}
	// 如果有其他goroutine正在写map，会抛错
	if h.flags&hashWriting != 0 {
		throw("concurrent map writes")
	}
	// 通过key和哈希种子，计算哈希值
	hash := t.hasher(key, uintptr(h.hash0))

	// Set hashWriting after calling t.hasher, since t.hasher may panic,
	// in which case we have not actually done a write.
	// 设置写标识位
	h.flags ^= hashWriting

	if h.buckets == nil {
		h.buckets = newobject(t.bucket) // newarray(t.bucket, 1)
	}

again:
	// 通过hash与bucketMask按位与操作，返回在buckets数组的第几号桶
	bucket := hash & bucketMask(h.B)
	// 如果map正在搬迁（即m.oldbuckets!=nil）中，则先进行搬迁工作
	if h.growing() {
		growWork(t, h, bucket)
	}
	// 计算出上面求出的第几号桶的内存位置
	b := (*bmap)(unsafe.Pointer(uintptr(h.buckets) + bucket*uintptr(t.bucketsize)))
	top := tophash(hash)

	var inserti *uint8
	var insertk unsafe.Pointer
	var elem unsafe.Pointer
bucketloop:
	for {
		// 遍历桶中的8个cell
		for i := uintptr(0); i < bucketCnt; i++ {
			// 这里分为两种情况
			// 第一种是cell位的tophash值和当前tophash值不相等，在b.tophash[i] != top的情况下
			// 理论上会有一个空槽位，一般情况下map的槽位分布是这样的，e表示empty
			// [h0][h1][h2][h3][h4][e][e][e]
			// 但执行过delete操作后，可能变成这样
			// [h0][h1][e][e][h5][e][e][e]
			// 所以如果后面再插入的话，会尽量往前面的位置插
			// 在循环的时候还要顺便把前面的空位置先记下来，因为有可能在后面找到相等的key
			if b.tophash[i] != top {
				// 如果cell位为空，那么就可以在对应位置进行插入
				if isEmpty(b.tophash[i]) && inserti == nil {
					// 赋值当前hash的高8位，标记写入成功
					inserti = &b.tophash[i]
					insertk = add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
					elem = add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
				}
				if b.tophash[i] == emptyRest {
					break bucketloop
				}
				continue
			}
			// 第二种情况是cell位的tophash值和当前tophash值相等
			k := add(unsafe.Pointer(b), dataOffset+i*uintptr(t.keysize))
			if t.indirectkey() {
				k = *((*unsafe.Pointer)(k))
			}
			// 即时当前cell位的tophash值相等，不代表它对应的key值也是相等的，所以还要做key值的判断
			if !t.key.equal(key, k) {
				continue
			}
			// already have a mapping for key. Update it.
			// 如果已经有该key了，就更新它
			if t.needkeyupdate() {
				typedmemmove(t.key, k, key)
			}
			// 这里获取到了要插入key对应的value的内存地址
			// pos = start + dataOffset + 8*keysize + i * elemsize
			elem = add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
			goto done
		}
		// 正常桶的bmap遍历完了，继续遍历溢出桶的bmap，如果有的话
		ovf := b.overflow(t)
		if ovf == nil {
			break
		}
		b = ovf
	}

	// 在已有的桶和溢出桶中都未找到合适的cell供key写入，那么有可能会触发以下两种情况
	// 1、判断当前map的装载因子是否达到设定的6.5阈值，或者当前map的溢出桶数量是否过多，如果存在这两种情况，进行扩容操作。
	// hashGrow()实际并未完成扩容，对哈希表数据的搬迁(复制)操作是通过growWork()来完成的
	// 重新进入again逻辑，在完成growWork()操作后，再次遍历新的桶
	// Did not find mapping for key. Allocate new cell & add entry.

	// If we hit the max load factor or we have too many overflow buckets,
	// and we're not already in the middle of growing, start growing.
	if !h.growing() && (overLoadFactor(h.count+1, h.B) || tooManyOverflowBuckets(h.noverflow, h.B)) {
		hashGrow(t, h)
		goto again // Growing the table invalidates everything, so try again
	}

	// 2、为当前桶新建新的溢出桶，并将tophash，key插入到新建溢出桶的对应内存的0号位置
	if inserti == nil {
		// all current buckets are full, allocate a new one.
		// 分配新的bmap写
		newb := h.newoverflow(t, b)
		inserti = &newb.tophash[0]
		insertk = add(unsafe.Pointer(newb), dataOffset)
		elem = add(insertk, bucketCnt*uintptr(t.keysize))
	}

	// store new key/elem at insert position
	// 在插入位置存入新的key和value
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
	// map中的key+1
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

插入key和查找key有几点不同：

- 如果找到待插入的key，则直接更新对应的value值
- 会在oldbucket中查找key，但不会再oldbucket中插入key
- 如果在bmap中没有找到待插入的key
  - 情况一：bmap中还有空位，在遍历bmap的时候预先标记可插入的空位，如果查找结束后也没有找到key，就把key放在预先标记的空位上
  - 情况二：bmap中没有空位了，此时检查一次是否达到了最大装载因子。如果达到了，立即进行扩容操作。扩容后在新桶中插入key，如果没有达到最大装载因子，则新生成一个bmap，并且把前一个bmap的overflow指针指向新的bmap。

> **迭代map的结果是无序的**
>
> map的遍历过程，是按序遍历bucket，同时按序遍历bucket和overflow里的cell。但是map在扩容后，会发生key的搬迁，这造成原来落在一个bucket中的key，搬迁后，有可能落在其他的bucket中。
> go为了保证遍历map的结果是无序的，做了以下事情：map在遍历时，并不是从固定的0号bucket开始遍历的，每次遍历，都会从一个随机值序号的bucket，再从其中随机的cell开始遍历。然后再按照桶序遍历下去，直到回到起始桶结束。

## 删除key

```go
func mapdelete(t *maptype, h *hmap, key unsafe.Pointer) {
	if h == nil || h.count == 0 {
		if t.hashMightPanic() {
			t.hasher(key, 0) // see issue 23734
		}
		return
	}
	if h.flags&hashWriting != 0 {
		throw("concurrent map writes")
	}

	// 计算key的哈希值
	hash := t.hasher(key, uintptr(h.hash0))

	// Set hashWriting after calling t.hasher, since t.hasher may panic,
	// in which case we have not actually done a write (delete).
	h.flags ^= hashWriting

	bucket := hash & bucketMask(h.B)
	// 如果在扩容中，继续扩容
	if h.growing() {
		growWork(t, h, bucket)
	}
	// 找到桶的位置
	b := (*bmap)(add(h.buckets, bucket*uintptr(t.bucketsize)))
	bOrig := b
	top := tophash(hash)
search:
	for ; b != nil; b = b.overflow(t) {
		// 遍历桶
		for i := uintptr(0); i < bucketCnt; i++ {
			if b.tophash[i] != top {
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
			// Only clear key if there are pointers in it.
			// 找到了key，开始清除key和对应的value
			if t.indirectkey() {
				// 如果指向的是指针，则指针置nil
				*(*unsafe.Pointer)(k) = nil
			} else if t.key.ptrdata != 0 {
				// 清除key的内存
				memclrHasPointers(k, t.key.size)
			}
			// 清除value
			e := add(unsafe.Pointer(b), dataOffset+bucketCnt*uintptr(t.keysize)+i*uintptr(t.elemsize))
			if t.indirectelem() {
				*(*unsafe.Pointer)(e) = nil
			} else if t.elem.ptrdata != 0 {
				memclrHasPointers(e, t.elem.size)
			} else {
				memclrNoHeapPointers(e, t.elem.size)
			}
			// 标记当前桶的当前槽位为空
			b.tophash[i] = emptyOne
			// If the bucket now ends in a bunch of emptyOne states,
			// change those to emptyRest states.
			// It would be nice to make this a separate function, but
			// for loops are not currently inlineable.
			if i == bucketCnt-1 {
				if b.overflow(t) != nil && b.overflow(t).tophash[0] != emptyRest {
					goto notLast
				}
			} else {
				if b.tophash[i+1] != emptyRest {
					goto notLast
				}
			}
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

删除key的流程和查找key的流程差不多：

- 找到对应的key后，清除对应的key和value。如果是指针类型，就把指针置为nil，如果是值就清空值对应的内存。
- 清除tophash里的值，并做一些标记
- 把hmap的计数器减1
- 如果是在扩容过程中，会在扩容完成后在新的bmap中执行删除操作

## 扩容

### 为什么要扩容？

因为，随着 Map 中添加的 key 越来越多，key 发生哈希冲突的概率也越来越大。桶中的 8 个槽位会被逐渐塞满，查找、插入、删除 key 的效率也会越来越低，因此需要在 Map 达到一定装载率后进行扩容，保证 Map 的读写性能。

Golang 衡量装载率的指标是**装载因子**，它的计算方式是：

```
loadFactor := count / (2^B)
```

其中：

- count 表示 Map 中的元素个数
- 2^B 表示桶数量

所以装载因子 loadFactor 的含义是平均每个桶装载的元素个数。Golang 定义的装载因子阈值是 6.5。

### 什么时候扩容？

插入 key 时会在以下两种情况触发哈希的扩容：

1. 装载因子超过 6.5，增量扩容；
2. 使用了太多溢出桶，等量扩容；

情况 2 中，溢出桶太多的判定标准是：

- B < 15 时，溢出桶数量 >= 2^B
- B >= 15 时，溢出桶数量 >= 2^15

```go
// mapassign中触发扩容的时机
if !h.growing() && (overLoadFactor(h.count+1, h.B) || tooManyOverflowBuckets(h.noverflow, h.B)) {
	hashGrow(t, h)
	goto again // Growing the table invalidates everything, so try again
}
```

```go
// overLoadFactor reports whether count items placed in 1<<B buckets is over loadFactor.
// 达到装载因子的临界点
func overLoadFactor(count int, B uint8) bool {
	return count > bucketCnt && uintptr(count) > loadFactorNum*(bucketShift(B)/loadFactorDen)
}

// tooManyOverflowBuckets reports whether noverflow buckets is too many for a map with 1<<B buckets.
// Note that most of these overflow buckets must be in sparse use;
// if use was dense, then we'd have already triggered regular map growth.
// 判断溢出桶是否太多。
// 当桶总数<2^15时，如果溢出桶>=桶总数，则认为溢出桶过多。
// 当桶总数>2^15时，当溢出桶>=2^15，则认为溢出桶过多
func tooManyOverflowBuckets(noverflow uint16, B uint8) bool {
	// If the threshold is too low, we do extraneous work.
	// If the threshold is too high, maps that grow and shrink can hold on to lots of unused memory.
	// "too many" means (approximately) as many overflow buckets as regular buckets.
	// See incrnoverflow for more details.
	if B > 15 {
		B = 15
	}
	// The compiler doesn't see here that B < 16; mask B to generate shorter shift code.
	return noverflow >= uint16(1)<<(B&15)
}
```

### 什么时候采用增量扩容策略？

触发扩容的第一种情况，随着map中不断插入新的元素，装载因子不断升高直至超过6.5，这时需要增量扩容。

增量扩容后，分配的新桶数量是旧桶的2倍

### 什么时候采用等量扩容策略？

触发扩容的第二种情况，在装载因子很小的情况，map的读写效率也很低。这种情况下map中的元素少，但是溢出桶多。

可能造成这种情况的原因是：不断插入元素，不断删除元素。

等量扩容后，分配的新桶数量和旧桶数量相同，但新桶中存储的数据更加紧密。

扩容的相关方法是`hashGrow()`，但它只是分配了新桶，并没有真正**迁移**数据

```go
// 没有真正搬迁，只是分配好新的buckets，并将老的buckets挂到oldbuckets字段上
func hashGrow(t *maptype, h *hmap) {
	// If we've hit the load factor, get bigger.
	// Otherwise, there are too many overflow buckets,
	// so keep the same number of buckets and "grow" laterally.
	// 看扩容类型
	bigger := uint8(1)
	if !overLoadFactor(h.count+1, h.B) {
		bigger = 0
		h.flags |= sameSizeGrow
	}
	// 记录老的buckets
	oldbuckets := h.buckets
	// 申请新的buckets空间
	newbuckets, nextOverflow := makeBucketArray(t, h.B+bigger, nil)

	// 转移标志位
	flags := h.flags &^ (iterator | oldIterator)
	if h.flags&iterator != 0 {
		flags |= oldIterator
	}
	// commit the grow (atomic wrt gc)
	// 提交grow
	h.B += bigger
	h.flags = flags
	h.oldbuckets = oldbuckets
	h.buckets = newbuckets
	// 搬迁进度为0
	h.nevacuate = 0
	// noverflow buckets数为0
	h.noverflow = 0

	// 如果发现hmap是通过extra字段来存储overflow buckets时
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

	// the actual copying of the hash table data is done incrementally
	// by growWork() and evacuate().
}
```

### 迁移

执行迁移工作的方法`growWork`

```go
func growWork(t *maptype, h *hmap, bucket uintptr) {
	// make sure we evacuate the oldbucket corresponding
	// to the bucket we're about to use
	// 为了确认搬迁的bucket是我们正在使用的bucket
	// 即如果当前key映射到老的bucket，那么就搬迁该bucket
	evacuate(t, h, bucket&h.oldbucketmask())

	// evacuate one more oldbucket to make progress on growing
	// 如果还未完成扩容
	if h.growing() {
		evacuate(t, h, h.nevacuate)
	}
}
```

负责迁移数据的方法`evacuate`

```go
func evacuate(t *maptype, h *hmap, oldbucket uintptr) {
	// 首先定位老的bucket的地址
	b := (*bmap)(add(h.oldbuckets, oldbucket*uintptr(t.bucketsize)))
	// newbit 代表扩容之前老的bucket个数
	newbit := h.noldbuckets()
	// 判断该bucket是否已经被搬迁
	if !evacuated(b) {
		// TODO: reuse overflow buckets instead of using new ones, if there
		// is no iterator using the old buckets.  (If !oldIterator.)

		// xy contains the x and y (low and high) evacuation destinations.
		// xy包含了高低区间的搬迁目的地内存信息
		// x.b 是对应的搬迁目标桶
		// x.k 是指向对应的目的桶中存储当前key的内存地址
		// x.e 是指向对应的目的桶中存储当前value的内存地址
		var xy [2]evacDst
		x := &xy[0]
		x.b = (*bmap)(add(h.buckets, oldbucket*uintptr(t.bucketsize)))
		x.k = add(unsafe.Pointer(x.b), dataOffset)
		x.e = add(x.k, bucketCnt*uintptr(t.keysize))

		// 只有当增量扩容时才计算bucket y的相关信息
		if !h.sameSizeGrow() {
			// Only calculate y pointers if we're growing bigger.
			// Otherwise GC can see bad pointers.
			y := &xy[1]
			y.b = (*bmap)(add(h.buckets, (oldbucket+newbit)*uintptr(t.bucketsize)))
			y.k = add(unsafe.Pointer(y.b), dataOffset)
			y.e = add(y.k, bucketCnt*uintptr(t.keysize))
		}

		// evacuate 每次只完成一个bucket的搬迁工作，因此需遍历完此bucket的所有cell，将有值的cell copy到新的地方
		// bucket还会链接overflow bucket，同样需要搬迁
		for ; b != nil; b = b.overflow(t) {
			k := add(unsafe.Pointer(b), dataOffset)
			e := add(k, bucketCnt*uintptr(t.keysize))
			// i,k,e对应tophash，key和value
			for i := 0; i < bucketCnt; i, k, e = i+1, add(k, uintptr(t.keysize)), add(e, uintptr(t.elemsize)) {
				top := b.tophash[i]
				// 如果当前cell的tophash是 emptyOne/emptyRest ，则代表此cell没有key，将其置为 evacuatedEmpty ，表示已经搬迁
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
				// 如果是增量扩容
				if !h.sameSizeGrow() {
					// Compute hash to make our evacuation decision (whether we need
					// to send this key/elem to bucket x or bucket y).
					// 计算哈希值，判断当前的key和value是否需要搬迁到bucket x/y
					hash := t.hasher(k2, uintptr(h.hash0))
					if h.flags&iterator != 0 && !t.reflexivekey() && !t.key.equal(k2, k2) {
						// If key != key (NaNs), then the hash could be (and probably
						// will be) entirely different from the old hash. Moreover,
						// it isn't reproducible. Reproducibility is required in the
						// presence of iterators, as our evacuation decision must
						// match whatever decision the iterator made.
						// Fortunately, we have the freedom to send these keys either
						// way. Also, tophash is meaningless for these kinds of keys.
						// We let the low bit of tophash drive the evacuation decision.
						// We recompute a new random tophash for the next level so
						// these keys will get evenly distributed across all buckets
						// after multiple grows.
						// 有一种特殊情况：有一种key，每次对它的计算hash得到的结果不一样。
						// 这个key就是 math.NaN() 的结果，它的含义是not a number，类型是float64
						// 把它当做map的key时，会遇到一个问题：再次计算它的哈希值和它刚插入map时计算的哈希值不一样
						// 这个key是永远不会被Get操作获取的，当使用m[math.NaN()]语句时，是查不出结果的，这个key只有在遍历整个map时，才能被找到
						// 并且，可以向一个 map 插入多个数量的 math.NaN() 作为 key，它们并不会被互相覆盖。
						// 当搬迁碰到 math.NaN() 的 key 时，只通过 tophash 的最低位决定分配到 X part 还是 Y part（如果扩容后是原来 buckets 数量的 2 倍）。
						// 如果 tophash 的最低位是 0 ，分配到 X part；如果是 1 ，则分配到 Y part。
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
				// useY要么为0，要么为1。这里就是选取在bucket x的起始内存位置，或者选择在bucket y的起始内存位置（只有增量同步才会有这个选择可能）。
				dst := &xy[useY] // evacuation destination

				// 如果目的地桶已经装满（8个cell），那么需要新建一个溢出桶，继续搬迁到溢出桶上去
				if dst.i == bucketCnt {
					dst.b = h.newoverflow(t, dst.b)
					dst.i = 0
					dst.k = add(unsafe.Pointer(dst.b), dataOffset)
					dst.e = add(dst.k, bucketCnt*uintptr(t.keysize))
				}
				dst.b.tophash[dst.i&(bucketCnt-1)] = top // mask dst.i as an optimization, to avoid a bounds check
				// 如果待搬迁的key是指针，则复制指针
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
				// 将当前搬迁目的桶的记录key/value的索引值（也可以理解为cell的索引值）加一
				dst.i++
				// These updates might push these pointers past the end of the
				// key or elem arrays.  That's ok, as we have the overflow pointer
				// at the end of the bucket to protect against pointing past the
				// end of the bucket.
				// 由于桶的内存布局中在最后还有overflow的指针，所以这里不用担心更新有可能会超出key和value数组的指针地址。
				dst.k = add(dst.k, uintptr(t.keysize))
				dst.e = add(dst.e, uintptr(t.elemsize))
			}
		}
		// Unlink the overflow buckets & clear key/elem to help GC.
		// 如果没有协程在使用老的桶，就对老的桶进行清理，用于帮助GC
		if h.flags&oldIterator == 0 && t.bucket.ptrdata != 0 {
			b := add(h.oldbuckets, oldbucket*uintptr(t.bucketsize))
			// Preserve b.tophash because the evacuation
			// state is maintained there.
			// 只清除bucket的key/value，保留top hash，指示搬迁状态
			ptr := add(b, dataOffset)
			n := uintptr(t.bucketsize) - dataOffset
			memclrHasPointers(ptr, n)
		}
	}

	// 更新搬迁进度
	if oldbucket == h.nevacuate {
		advanceEvacuationMark(h, t, newbit)
	}
}
```

对于增量扩容，需要重新计算key的哈希值，才能确定它落在哪个桶。例如，原来B=5，计算出key的哈希值后，只用看它的低5位，就能确定它落在哪个桶。扩容后，B变成了6，就需要看低6位决定key落在哪个桶，这个过程被称为`rehash`。

因此，某个key在迁移前后，所在的桶的序号可能和原来相同，也可能在原来基础上加`2^B`（原来的B值），这取决于哈希值的第6位是0还是1。

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/14/map_equal.png)

![](https://cdn.jsdelivr.net/gh/betterfor/cloudImage/images/2021/07/14/map_increment1.webp)

# 关于Golang Map的线程安全

Golang 标准包里的 Map 非线程安全， 它支持并发读取同一个 Map， 但不支持并发写同一个 Map，goroutine 并发写同一个 Map 会引发报错：fatal error: concurrent map writes

[官方解释](https://golang.org/doc/faq#atomic_maps)是经过长时间的讨论， 绝大多数 Map 的使用场景并不需要线程安全。在那些极少数需要 Map 支持线程安全的场景中，Map 被用来存储海量共享数据，这种情况下必须加锁来确保数据一致，而加锁显然会影响性能和安全性。

如果需要并发读写map，可以使用以下方法：

- 读写map时加锁
- 使用sync.map
- [concurrent-map](https://github.com/orcaman/concurrent-map)

# 总结

map是哈希表实现，通过链地址法解决哈希冲突，核心数据结构是数组加链表。

map中定义了2^B个桶，每个桶中能容纳8个key。根据key的不同哈希值，将其散落到不同的桶中。哈希值的低位（哈希值的后B个bit位）决定桶号，高位（哈希值的前8位）标识同一个桶中的不同key。

当向桶中添加很多key，造成元素过多，超过装载因子所设定的程度，或多次增删操作，造成溢出桶过多，均会触发扩容。

扩容分为增量扩容和等量扩容。
增量扩容，会增加桶的个数（增加一倍），把原来一个桶中的 keys 被重新分配到两个桶中。
等量扩容，不会更改桶的个数，只是会将桶中的数据变得紧凑。不管是增量扩容还是等量扩容，都需要创建新的桶数组，并不是原地操作的。

扩容过程是渐进性的，主要是防止一次扩容需要搬迁的 key 数量过多，引发性能问题。
触发扩容的时机是增加了新元素， 桶搬迁的时机则发生在赋值、删除期间，每次最多搬迁两个 桶。查找、赋值、删除的一个很核心的内容是如何定位到 key 所在的位置，需要重点理解。

# 参考资料

[1.8 万字详解 Go 是如何设计 Map 的](https://mp.weixin.qq.com/s?__biz=MzAxMTA4Njc0OQ==&mid=2651442371&idx=2&sn=54a270a6dba5536451391b66b8ebdd86&chksm=80bb1231b7cc9b271d3bc12d6b887d3b370d05f270993960f5ca50ef0b2769c90f71b63f5fdf&scene=21#wechat_redirect)

[深入理解Golang Map](https://mp.weixin.qq.com/s/gdzeDxD8zQopcIUYiLgjbw)
