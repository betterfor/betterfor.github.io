# 二维数组按行和按列遍历的效率


## 二维数组的排列顺序

数组在内存中是按行存储的，按行遍历时可以由指向数组的第一个数的指针一直向后遍历，由于二维数组的内存地址是连续的，当前行的尾和下一行的头相邻。

用代码来打印数组的地址。

```go
func main() {
    var a int32
	fmt.Println(unsafe.Sizeof(a))
	n := 4
	array := generateArray(n)
	for i := 0; i < n; i++ {
		fmt.Printf("%p \n",array[i])
	}
}

func generateArray(n int) [][]int32 {
	var arr = make([][]int32,n)
	for i := 0; i < n; i++ {
		arr[i] = make([]int32,n)
		for j := 0; j < n; j++ {
			arr[i][j] = 1
		}
	}
	return arr
}

// Output:
4
0xc0000a0090 
0xc0000a00a0 
0xc0000a00b0 
0xc0000a00c0
```

> int32占用4个字节，4个int32占用16个字节，这与我们得到一个数组的地址是对应的。

**我们眼中的二维数组**

![我们眼中的二维数组](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/08/我们眼中的二维数组.png)

**内存中的二维数组**

![计算机眼中的二维数组](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/08/计算机眼中的二维数组.png)

那么二维数组按行遍历相当于按照内存顺序读取，而按列遍历不按内存顺序读取。

按行读取比按列读取的效率高体现在以下几个方面：

- CPU高速缓存：在计算机系统中，CPU高速缓存（英语：CPU Cache，在本文中简称缓存）是用于减少处理器访问内存所需平均时间的部件。在金字塔式存储体系中它位于自顶向下的第二层，仅次于CPU寄存器。其容量远小于内存，但速度却可以接近处理器的频率。当处理器发出内存访问请求时，会先查看缓存内是否有请求数据。如果存在（命中），则不经访问内存直接返回该数据；如果不存在（失效），则要先把内存中的相应数据载入缓存，再将其返回处理器。缓存之所以有效，主要是因为程序运行时对内存的访问呈现局部性（Locality）特征。这种局部性既包括空间局部性（Spatial Locality），也包括时间局部性（Temporal Locality）。有效利用这种局部性，缓存可以达到极高的命中率。
- 缓存从内存中抓取一般都是整个数据块，所以它的物理内存是连续的，几乎都是同行不同列的，而如果内循环以列的方式进行遍历的话，将会使整个缓存块无法被利用，而不得不从内存中读取数据，而从内存读取速度是远远小于从缓存中读取数据的。随着数组元素越来越多，按列读取速度也会越来越慢。

#### 代码验证

```go
func main() {
	arr := generateArray(2000)
	t0 := time.Now()
	readCols(arr)
	t1 := time.Now()
	readRows(arr)
	t2 := time.Now()
	fmt.Println(t1.Sub(t0),t2.Sub(t1))
}

func generateArray(n int) [][]int32 {
	var arr = make([][]int32,n)
	for i := 0; i < n; i++ {
		arr[i] = make([]int32,n)
		for j := 0; j < n; j++ {
			arr[i][j] = 1
		}
	}
	return arr
}

func readCols(arr [][]int) {
	for i := 0; i < len(arr); i++ {
		for j := 0; j < len(arr[0]); j++ {
			arr[i][j] = 1
		}
	}
}

func readRows(arr [][]int) {
	for i := 0; i < len(arr); i++ {
		for j := 0; j < len(arr[0]); j++ {
			arr[j][i] = 1
		}
	}
}
```

可以验证按列读取的时间远远大于按行读取。
