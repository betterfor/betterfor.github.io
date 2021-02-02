# LEETCODE 888. 公平的糖果交换


大家好，我是沉迷于刷题的小耗。

今天给大家带来的是力扣888题：**公平的糖果棒交换**

## 题目

爱丽丝和鲍勃有不同大小的糖果棒：`A[i]` 是爱丽丝拥有的第 `i` 块糖的大小，`B[j]` 是鲍勃拥有的第 `j` 块糖的大小。

因为他们是朋友，所以他们想交换一个糖果棒，这样交换后，他们都有相同的糖果总量。（一个人拥有的糖果总量是他们拥有的糖果棒大小的总和。）

返回一个整数数组 `ans` ，其中 `ans[0]` 是爱丽丝必须交换的糖果棒的大小，`ans[1]` 是 Bob 必须交换的糖果棒的大小。

如果有多个答案，你可以返回其中任何一个。保证答案存在。

### 示例
<p><strong>示例 1：</strong></p>

<pre><strong>输入：</strong>A = [1,1], B = [2,2]
<strong>输出：</strong>[1,2]
</pre>

<p><strong>示例 2：</strong></p>

<pre><strong>输入：</strong>A = [1,2], B = [2,3]
<strong>输出：</strong>[1,2]
</pre>

<p><strong>示例 3：</strong></p>

<pre><strong>输入：</strong>A = [2], B = [1,3]
<strong>输出：</strong>[2,3]
</pre>

<p><strong>示例 4：</strong></p>

<pre><strong>输入：</strong>A = [1,2,5], B = [2,4]
<strong>输出：</strong>[5,4]
</pre>
## 题解

这是一道简单题，很明显我们可以有一个思路，既然答案确定存在，那么最终两个的糖果数相等，那么记爱丽丝的糖果棒总数为 `sumA`,鲍勃的糖果棒总数为 `sumB`,记最终答案为`{x,y}`,即爱丽丝的大小为x的糖果棒和鲍勃的大小为y的糖果棒交换，有等式

$$
sumA-x+y=sumB+x-y
$$
化简，得:
$$
x=y+(sumA-sumB)/2
$$

为了快速查询`A`中是否存在某个数，可以先将`A`中的数字放入哈希表中，然后遍历`B`

```go
func fairCandySwap(A []int, B []int) []int {
	var sumA,sumB int
	var mapA = make(map[int]struct{},len(A))
	for _, a := range A {
		sumA += a
		mapA[a] = struct{}{}
	}
	for _, b := range B {
		sumB += b
	}
	diff := (sumA- sumB)/2
	for _, b := range B {
		a := b+diff
		if _, ok := mapA[a]; ok {
			return []int{a,b}
		}
	}
	return nil
}
```

## 复杂度分析
时间复杂度: O(m+n),m是A的长度,n是B的长度

空间复杂度: O(m)

![执行结果](https://gitee.com/zongl/cloudImage/raw/master/images/2021/02/01/888-01.png)