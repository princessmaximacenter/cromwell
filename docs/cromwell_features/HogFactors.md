# Hog Factors

As of Cromwell 35, Cromwell introduces the concept hog factor (along with the related of hog groups and hog limits).

## Concepts

### Hog Group

- Every workflow is assigned to a hog group when Cromwell receives it. Exactly how this happens is [configurable](#configuration).
- Any sub-workflow or job triggered by the workflow is associated with the same hog group as its parent.

Thus:

- Every workflow is assigned to exactly one hog group.
- Every hog group may have many workflows assigned to it.

The limits discussed below happen at the granularity of the hog group.

### Hog Factor

The hog factor is an integer greater than or equal to 1. It represents a trade-off between: 

- Maximizing the resources of Cromwell and allowing jobs to be processed as fast as possible.
- Remaining responsive to small requests from other groups - even if a few greedy groups have enough work that they 
could otherwise max out Cromwell's limits by themselves.

Here are a few mental models which might be helpful to thinking about the hog factor:

- A hog factor of 2 means that "2 greedy users would be able to hog the entire resources of Cromwell" 
- A hog factor of 100 means "any 1 group is only ever allowed to use 1/100th of the resources of the total Cromwell server"

### Hog Limit

Hog Limits are not set directly, but are values that Cromwell calculates internally. 
They are the evaluated upper bounds on how much of a given resource type could be given, in total, to workflows within 
a single greedy group (for example in the sentence "this Cromwell has calculated a hog limit of 2 jobs per group"). 

## Configuration

Cromwell accepts two configuration values for hog factors in the `hog-safety` stanza of the configuration file:
```conf
  hog-safety {
    workflow-option = "hogGroup"
    hog-factor = 1
  }
```

### Setting a hog-factor

The hog factor option sets the integer described in the [Hog Factor](#hog-factor) section above.
The default value is `1` (which is equivalent to not limiting by hog group). 

### Assignment of hog groups

Within the configuration file, you can specify the workflow option that will determine the hog group:

- The default is `hogGroup`
- Therefore, if a workflow arrives with the following workflow options file, Cromwell will assign `hogGroupA` as the
workflow's hog group:
```json
{
  "hogGroup": "hogGroupA"
}
```

- Any `String` field can be chosen from workflow options:
    + You can come up with a new field and set it specifically for assigning hog groups.
    + You can choose a field that is already being used for other reasons
- If a workflow is submitted which does have the designated field in its workflow options, the workflow ID is used as
the hog group. 

## Effects

### Job Execution

#### Reserving Space

- Cromwell allows administrators to designate an overall maximum concurrent job limit per backend. 
- Within that limit, hog factors now allow us to limit the maximum concurrent jobs started per hog group.
    + This means that new workflows can immediately run even if big workflows are queued up.

#### Round robin allocation

Rather than assigning job tokens on a strict first-come first served basis, Cromwell now assigns in a round-robin
fashion between hog groups and then on a first-come-first-served *within* a hog group.

In other words if the hog groups had the following entries queued up:
```
 A: jobA1, jobA2, jobA3, ..., jobA1000000
 B: jobB1, jobB2
 C: jobC1
 D: jobD1, jobD2
```

Then Cromwell would start the jobs in the following order, even though `jobA1000000` was added before `jobD1`:
```
jobA1, jobB1, jobC1, jobD1, jobA2, jobB2, jobD2, jobA3, ..., jobA1000000
```

#### Example: How job execution is affected by hog factors

##### An administrator sets up a Cromwell server

- A Cromwell administrator sets the overall maximum concurrent job limit to 100,000 PAPIv2 jobs.
- The administrator also sets the hog factor to be 25.
- Cromwell will therefore calculate a per-hog-group concurrent job limit of 4,000 PAPIv2 jobs.

##### Our first hog group hits its limit

- 100 workflows are running in hog group "A" and between them want to send 20,000 jobs to PAPIv2. 
    + Cromwell will initially limit that to 4,000 and only start new jobs when existing jobs from this group finish.
    + New workflows in this group will not be able to start jobs either until existing jobs complete.
    + Note that Cromwell is only using 1/25th of its limit even though it would otherwise be able to go faster.

##### Another hog group appears

- Now hog group B submits 1,000 workflows and between them they want to send 200,000 jobs to PAPIv2.
- Even though group A's jobs are only trickling in, group B's workflows are allowed to start 4,000 jobs immediately,
- The rest of group B's jobs are queued up waiting for group B's existing jobs to complete.

##### Where do we stand?

- Cromwell knows about 220,000 jobs that could be started
- Cromwell has an overall limit of 100,000
- Cromwell is running 8,000 jobs in two hog groups.

In other words, not so great - perhaps we should have set the hog factor lower...?

#####But wait, more workflows appear...

- Now another 23 hog groups ("C" through "Y") submit workflows of a similar scale to hog group A.
- One by one, the workflows of each hog group fill up their share of the overall concurrent job limit.
- So Cromwell is now running 100,000 jobs and each hog group has been allocated 4,000 of those.

##### What about poor hog group "Z"?

- A final group submits workflows under hog group "Z".
- Alas, even though hog group "Z" is not running anything yet, we cannot start their workflows because we're 
at the global maximum of 100,000.


In other words, perhaps we should have set the hog factor higher...?

##### So what now?

- As jobs in other hog group complete, we will begin to see hog group "Z" jobs started alongside new jobs from the 
other hog groups.
- Going forward Cromwell will start jobs from all groups at the same rate, even though hog group Z's jobs arrived
later than those from hog group A. Thus, over time, each group will approach approximately 1/26th of the total pool.
  
## FAQs

#### Can I opt out of using hog groups?

Yes, to various degrees:

- No matter what, your workflows will be assigned to a hog group. 
- To opt out of reserving Cromwell's resources for new hog groups, set your hog factor to 1.
- To opt out of round-robin allocation between workflows, assign all workflows to the same hog-group in workflow options.


