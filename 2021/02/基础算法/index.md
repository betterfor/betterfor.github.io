# 基础排序算法


## 排序算法

所谓的排序算法就是将一串记录，按照递增或递减的顺序排列起来。

>  通常提到的一共有十种排序：冒泡、选择、插入、快速、归并、堆、希尔、计数、桶、基数

- **比较类排序**：通过比较来决定元素间的相对次序，通常其时间复杂度不能突破`O(nlogn)`，因此又称为非线性时间比较类排序。

- **非比较类排序**：不通过比较元素间的相对次序，可以突破基于比较排序的时间下限，以线性时间运行，因此又称为线性时间非比较类排序。

*时间复杂度：*

| 排序方法 | 时间复杂度(平均) | 时间复杂度(最坏) | 时间复杂度(最好) | 空间复杂度 | 稳定性 |
| :------: | :--------------: | :--------------: | :--------------: | :--------: | :----: |
| 冒泡排序 |     O(n^2^)      |     O(n^2^)      |       O(n)       |    O(1)    |  稳定  |
| 选择排序 |     O(n^2^)      |     O(n^2^)      |     O(n^2^)      |    O(1)    | 不稳定 |
| 插入排序 |     O(n^2^)      |     O(n^2^)      |       O(n)       |    O(1)    |  稳定  |
| 快速排序 |     O(nlogn)     |     O(n^2^)      |     O(nlogn)     |  O(nlogn)  | 不稳定 |
| 归并排序 |     O(nlogn)     |     O(nlogn)     |     O(nlogn)     |    O(n)    |  稳定  |
|  堆排序  |     O(nlogn)     |     O(nlogn)     |     O(nlogn)     |    O(1)    | 不稳定 |
| 希尔排序 |    O(n^1.3^)     |     O(n^2^)      |       O(n)       |    O(1)    |  稳定  |
|          |                  |                  |                  |            |        |
| 计数排序 |      O(n+k)      |      O(n+k)      |      O(n+k)      |   O(n+k)   |  稳定  |
|  桶排序  |      O(n+k)      |     O(n^2^)      |       O(n)       |   O(n+k)   |  稳定  |
| 基数排序 |      O(n*k)      |      O(n*k)      |      O(n*k)      |   O(n+k)   |  稳定  |

> 稳定性：如果a=b，并且a在b的前面，排序后a一定在b的前面，那么称算法是稳定的，如果不一定在前面，那么称算法是不稳定的。

## 冒泡排序

冒泡排序(Bubble Sort)是一种简单直观的排序算法。它重复地访问要排序的数列，一次比较两个元素，如果顺序错误就调换顺序。走访数列的工作是重复地进行指导没有再需要元素交换，也就是说该数列已经排序完成。由于越小的元素会经过交换慢慢地到达顶端，就像泡泡一样会上浮，所以称为冒泡排序。

---

#### 1、算法步骤

​	1、比较相邻的元素，如果第一个比第二个大，就交换它们。

​	2、对每一对相邻元素做同样的工作，从开始第一对到结尾的最后一对，这步做完后，末尾元素是最大的元素。

​	3、针对所有的元素重复以上步骤，除了最后一个元素

​	4、重复步骤`1~3`，直到没有任意一对元素需要比较。

---

#### 2、动画演示

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/07/冒泡排序.gif)

---

#### 3、情况

最好情况：数列是正序，只需要遍历一遍，时间复杂度最好为O(n)。

最坏情况：数列是倒序，每一对都需要进行比较，时间复杂度最坏为O(n^2^)。

时间复杂度平均为O(n^2^)，空间复杂度为O(1)，是稳定排序。

---

#### 4、Golang实现

```go
func bubbleSort(arr []int) {
	n := len(arr)
	for i := 0; i < n-1; i++ {
		for j := i + 1; j < n; j++ { 
			if arr[i] > arr[j] {
				arr[i], arr[j] = arr[j], arr[i]
			}
		}
	}
}
```

## 选择排序

选择排序(Selection Sort)是一种简单直观的排序算法。它的工作原理是：首先在序列中找到最小元素，放在序列的首位，然后再从剩下的序列中寻找最小元素，放到已排序序列的末尾。

---

#### 1、算法步骤

​	1、首先在未排序序列中找到最小元素，存放到排序序列的起始位置

​	2、再从剩余未排序序列中继续寻找最小元素，存放到排序序列的末尾

​	3、重复第2步，直到所有元素排序完毕。

---

#### 2、动画演示

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/07/选择排序.gif)

---

#### 3、情况

时间复杂度为O(n^2^)，因为无论如何都需要遍历序列找到最小值，所以最好和最坏都是O(n^2^)。

空间复杂度为O(n^2^)，是不稳定排序。

---

#### 4、Golang实现

```go
func selectionSort(arr []int) {
	for i := 0; i < len(arr); i++ {
		min := i
		for j := i + 1; j < len(arr); j++ {
			if arr[j] < arr[min] {
				min = j
			}
		}
		arr[min], arr[i] = arr[i], arr[min]
	}
}
```

## 插入排序

插入排序(Insertion Sort)是一种简单直观的排序算法。它的工作原理是通过构建有序序列，对于未排序数据，在已排序序列由后向前扫描，找到相应位置并插入。

---

#### 1、算法步骤

​	1、把第一个元素看成一个有序序列，把第二个元素到最后一个元素看成一个未排序序列。

​	2、从头扫描，将扫描到的每个元素插入有序序列的适当位置。

---

#### 2、动画演示

![插入排序](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/07/插入排序.gif)

---

#### 3、情况

最坏情况：每一个待插入的元素都需要插入到序列首位，即原序列是倒序序列，时间复杂度为O(n^2^)。

最好情况：每一个待插入的元素都需要插入到序列末位，即原序列是正序序列，时间复杂度为O(n) 。

时间复杂度平均为 O(n^2^)，空间复杂度为O(1) 是稳定排序。

---

#### 4、Golang实现

```go
func insertionSort(arr []int) {
	for i := 1; i < len(arr); i++ {
		current := arr[i]
		preIndex := i - 1
		for ; preIndex >= 0 && current < arr[preIndex]; preIndex-- {
			arr[preIndex+1] = arr[preIndex]
		}
		arr[preIndex+1] = current
	}
}
```

## 快速排序

快速排序(Quick Sort)是通过一趟排序将待排记录分隔成独立的两部分，其中一部分的关键字比另一部分的关键字小，则可分别对这两部分记录继续进行排序，直到整个序列有序。

---

#### 1、算法步骤

​	1、从序列中挑出一个元素，作为基准。

​	2、重新排列数列，所有元素比基准小的放在基准前面，所有元素比基准大的放在基准后面。

​	3、递归地把小于基准元素的子序列和大于基准元素的子序列排序。

---

#### 2、动画演示

![快速排序](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/07/快速排序.gif)

---

#### 3、情况

时间复杂度平均为O(nlogn) ，空间复杂度为O(nlogn)，是不稳定排序。

---

#### 4、Golang实现



## 归并排序

归并排序(Merge Sort)是建立在归并操作上的一种有效排序算法，采用了分而治之的思想。

---

#### 1、算法步骤

​	1、把长度为n的序列分为两个长度为n/2的子序列。

​	2、对这两个子序列分别采用归并排序。

​	3、将两个排序好的子序列合并成一个最终的排序序列。

---

#### 2、动画演示

![归并排序](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/07/归并排序.gif)

---

#### 3、情况

时间复杂度为O(nlogn)，空间复杂度为O(n)，是稳定排序方法。

---

#### 4、Golang实现

```go
func mergeSort(nums []int, start,end int) {
	if start < end {
		mid := (start+end)/2
		mergeSort(nums,start,mid) // 左边排序
		mergeSort(nums,mid+1,end) // 右边排序
		merge(nums,start,mid,end) // 合并数组
	}
}

func merge(nums []int, start, mid, end int) {
	i,j := start,mid+1
	ret := []int{}
	for i <= mid && j <= end {
		if nums[i] <= nums[j] {
			ret = append(ret, nums[i])
			i++
		} else {
			ret = append(ret, nums[j])
			j++
		}
	}
	ret = append(ret, nums[i:mid+1]...)
	ret = append(ret, nums[j:end+1]...)
	for k, v := range ret {
		nums[start+k] = v
	}
}
```

## 堆排序

堆排序(Heap Sort)是指利用堆这种数据结构所设计的一种排序算法。堆是一种近似于完全二叉树的结构，并同时满足堆积的性质：子节点的键值或索引总小于(或大于)父节点。

大根堆：每个节点的值都大于或等于其子节点的值，在堆排序算法中用于升序排列；

小根堆：每个节点的值都小于或等于其子节点的值，在堆排序算法中用于降序排列；

---

#### 1、算法步骤

​	1、将待排序列构建成一个堆 H[0......n-1]，根据(升序降序)选择大根堆或小跟堆。

​	2、把堆顶和堆尾互换。

​	3、把堆的尺寸缩小 1，并调用 shift_down(0)，目的是把新的数组顶端数据调整到相应位置；

​	4、重复步骤 2，直到堆的尺寸为 1。

---

#### 2、动画演示

![堆排序](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/07/堆排序.gif)

---

#### 3、情况

时间复杂度平均为O(nlogn) ，空间复杂度 O(1)， 是不稳定排序。

---

#### 4、Golang实现

```go
func heapSort(arr []int) []int {
	arrLen := len(arr)
	buildMaxHeap(arr, arrLen)
	for i := arrLen - 1; i >= 0; i-- {
		swap(arr, 0, i)
		arrLen -= 1
		heapify(arr, 0, arrLen)
	}
	return arr
}

func buildMaxHeap(arr []int, arrLen int) {
	for i := arrLen / 2; i >= 0; i-- {
		heapify(arr, i, arrLen)
	}
}

func heapify(arr []int, i, arrLen int) {
	left := 2*i + 1
	right := 2*i + 2
	largest := i
	if left < arrLen && arr[left] > arr[largest] {
		largest = left
	}
	if right < arrLen && arr[right] > arr[largest] {
		largest = right
	}
	if largest != i {
		swap(arr, i, largest)
		heapify(arr, largest, arrLen)
	}
}

func swap(arr []int, i, j int) {
	arr[i], arr[j] = arr[j], arr[i]
}
```

## 希尔排序

希尔排序是插入排序的改进版本，与插入排序不同之处在于，它会优先比较距离较远的元素，又称**缩小增量排序**。

基本思想是：先将整个待排序的序列分割成若干个子序列分别进行插入排序，待整个序列“基本有序”时，在依次进行插入排序。

---

#### 1、算法步骤

​	1、选择一个增量序列 t1,t2, ......, tk，其中ti > tj，tk=1;

​	2、按增量序列个数k，对序列进行k趟排序

​	3、每趟排序，根据对应的增量ti，将待排序分割成若干长度为m的子序列，分别对各子表进行直接插入排序。当增量因子为1时，整个序列作为一个表来处理，表长度即为整个序列的长度。

---

#### 2、动画演示

![](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/07/希尔排序.gif)

---

#### 3、Golang实现

```go
func shellSort(arr []int) {
	n := len(arr)
	for step := n / 2; step >= 1; step /= 2 {
		for i := step; i < n; i += step {
			for j := i - step; j >= 0; j -= step {
				if arr[j] > arr[j+step] {
					arr[j], arr[j+step] = arr[j+step], arr[j]
					continue
				}
				break
			}
		}
	}
}
```

## 计数排序

计数排序(Counting Sort)不是基于比较的排序算法，其核心在于将输入的数据值转化为键存储在额外开辟的数组空间中。作为一种线性时间复杂度的排序，计数排序要求输入的数据必须是有确定范围的整数。

---

#### 1、算法步骤

​	1、找出原数组中元素最大值，记为max。

​	2、创建一个新数组count，其长度是max+1，其元素默认为0 。

​	3、遍历原数组中的元素，以原数组中的元素作为count数组的索引，以原数组中出现的元素次数作为count数组的元素值。

​	4、创建结果数组result，起始索引index。

​	5、遍历count数组，找出其中元素值大于0的元素，将其对应的索引作为元素值填充到result数组中去，每处理一次，count中的该元素值减1，直到该元素值不大于0，依次处理count中剩下的元素。

​	6、返回结果数组result。

---

#### 2、动画演示

![计数排序](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/07/计数排序.gif)

---

#### 3、情况

时间复杂度为O(n+k)，空间复杂度为O(n+k)，是稳定排序。

---

#### 4、Golang实现

```go
func countingSort(arr []int, maxVal int) {
	n := maxVal+1
	nums := make([]int,n)
	var sortedIndex int
	for i := 0; i < len(arr); i++ {
		nums[arr[i]]++
	}
	for i := 0; i < n; i++ {
		for nums[i] > 0 {
			arr[sortedIndex] = i
			sortedIndex++
			nums[i]--
		}
	}
}
```

## 桶排序

桶排序(Bucket Sort)是计数排序的升级版，利用函数的映射关系，高效与否的关键在于映射函数的确定。假设输入数据服从均匀分布，将数据分到有限数量的桶里，每个桶再分别排序（有可能再使用别的排序算法或是以递归方式继续使用桶排序进行排）。

---

#### 1、算法步骤

​	1、设置一个定量的数组当做空桶。

​	2、遍历数据，并且把数据一个个放入到对应的桶中。

​	3、对每个不是空桶进行排序。

​	4、从不是空桶里把排好序的数据拼接起来。

---

#### 2、动画演示

![桶排序](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/07/桶排序.gif)

---

#### 3、情况

最好情况：当输入的数据均匀分配到每个桶中，时间复杂度为 O(n) 。

最坏情况：输入的数据被分配到同一个桶中，时间复杂度O(n^2^) 。

时间复杂度平均为O(n+k) ，空间复杂度为O(n+k)，是稳定排序算法。

---

#### 4、Golang实现

```go
func quickSort(nums []int, start, end int) []int {
	if start < end {
		i, j := start, end
		key := nums[(start+end)/2]
		for i <= j {
			for nums[i] < key {
				i++
			}
			for nums[j] > key {
				j--
			}
			if i <= j {
				nums[i], nums[j] = nums[j], nums[i]
				i++
				j--
			}
		}
		if start < j {
			nums = quickSort(nums, start, j)
		}
		if end > i {
			nums = quickSort(nums, i, end)
		}
	}
	return nums
}
func bucketSort(nums []int, bucketNum int) []int {
	bucket := [][]int{}
	for i := 0; i < bucketNum; i++ {
		tmp := make([]int, 1)
		bucket = append(bucket, tmp)
	}
	//将数据分配到桶中
	for i := 0; i < len(nums); i++ {
		bucket[nums[i]/bucketNum] = append(bucket[nums[i]/bucketNum], nums[i])
	}
	//循环所有的桶进行排序
	index := 0
	for i := 0; i < bucketNum; i++ {
		if len(bucket[i]) > 1 {
			//对每个桶内部进行排序,使用快排
			bucket[i] = quickSort(bucket[i], 0, len(bucket[i])-1)
			for j := 1; j < len(bucket[i]); j++ {
				//去掉一开始的tmp
				nums[index] = bucket[i][j]
				index++
			}
		}
	}
	return nums
}
```

## 基数排序

基数排序(Radix Sort)的原理是按照整数位数切割成不同的数字，然后按每个位数分别比较。

然后我们发现，计数排序、桶排序、基数排序都用到了桶的概念。

- 计数排序：每个桶只存单一键值
- 基数排序：根据键值的每位数字来分配桶
- 桶排序：每个桶存储一定范围的数值

---

#### 1、算法步骤

​	1、取得数组中的最大数，并取得位数

​	2、arr为原始数组，从最低位开始取个位组成radix数组

​	3、对radix进行计数排序

---

#### 2、动画演示

![基数排序](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/07/基数排序.gif)

---

#### 3、情况

时间复杂度为O(n*k)，空间复杂度为O(n+k)，是稳定排序算法。

---

#### 4、Golang实现

```go
func RadixSort(arr[] int) []int{
	if len(arr)<2{
		return arr
	}
	maxl:=MaxLen(arr)
	return RadixCore(arr,0,maxl)
}
func RadixCore(arr []int,digit,maxl int) []int{
	if digit>=maxl{
		return arr
	}
	radix:=10
	count:=make([]int,radix)
	bucket:=make([]int,len(arr))
	for i:=0;i<len(arr);i++{
		count[GetDigit(arr[i],digit)]++
	}
	for i:=1;i<radix;i++{
		count[i]+=count[i-1]
	}
	for i:=len(arr)-1;i>=0;i--{
		d:=GetDigit(arr[i],digit)
		bucket[count[d]-1]=arr[i]
		count[d]--
	}
	return RadixCore(bucket,digit+1,maxl)
}
func GetDigit(x,d int) int{
	a:=[]int{1,10,100,1000,10000,100000,1000000}
	return (x/a[d])%10
}
func MaxLen(arr []int) int{
	var maxl,curl int
	for i:=0;i<len(arr);i++{
		curl=len(strconv.Itoa(arr[i]))
		if curl>maxl{
			maxl=curl
		}
	}
	return maxl
}
```